import AppKit
import SwiftUI
import WebKit
import CryptoKit
import Darwin

// Line-buffer stdout so JSONL stream events appear immediately even when piped.
setlinebuf(stdout)

// MARK: - Model

/// A single comment. Threads are formed by `replyTo` pointers — a root is a
/// comment with `replyTo == nil`. Only the root carries authoritative
/// `anchorLine` / `anchorText` / `resolved` / `orphaned` values; replies
/// inherit at render time.
struct Comment: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var replyTo: UUID? = nil
    var anchorLine: Int
    var anchorText: String
    var body: String
    var author: String
    var createdAt: Date = Date()
    var resolved: Bool = false
    var orphaned: Bool = false
}

struct CommentFile: Codable {
    var file: String
    var sourceHash: String
    var comments: [Comment]
}

struct ViewerPayload: Codable {
    let source: String
    let comments: [Comment]
}

struct FileSummary: Codable {
    let file: String
    let comments: [Comment]
}

struct ReanchorStats: Codable {
    let unchanged: Int
    let relocated: Int
    let orphaned: Int
}

struct StreamEvent: Codable {
    let event: String              // session_start | added | edited | deleted | resolved | reopened | reloaded | opened | focused | pong | exit
    let timestamp: Date
    let file: String?
    let comment: Comment?
    let files: [FileSummary]?
    let reanchor: ReanchorStats?
}

extension String {
    func sha256Prefix() -> String {
        let d = SHA256.hash(data: Data(self.utf8))
        return d.compactMap { String(format: "%02x", $0) }.joined().prefix(16).description
    }
}

func emitEvent(_ ev: StreamEvent) {
    let enc = JSONEncoder()
    enc.dateEncodingStrategy = .iso8601
    if let data = try? enc.encode(ev), let s = String(data: data, encoding: .utf8) {
        print(s)
        fflush(stdout)
    }
}

/// Append a single JSON event to the per-file event log (FILE.md.events.jsonl).
/// Best-effort: never throws, never crashes the caller on log write failure.
enum EventLog {
    static func append(_ ev: StreamEvent, for fileURL: URL) {
        let logURL = fileURL.appendingPathExtension("events.jsonl")
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard var data = try? enc.encode(ev) else { return }
        data.append(0x0A)  // newline
        do {
            if !FileManager.default.fileExists(atPath: logURL.path) {
                try data.write(to: logURL)
            } else {
                let h = try FileHandle(forWritingTo: logURL)
                try h.seekToEnd()
                try h.write(contentsOf: data)
                try h.close()
            }
        } catch {
            // intentionally swallowed — log write must never break a mutation
        }
    }

    static func appendRaw(_ obj: [String: Any], for fileURL: URL) {
        let logURL = fileURL.appendingPathExtension("events.jsonl")
        guard var data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        data.append(0x0A)
        do {
            if !FileManager.default.fileExists(atPath: logURL.path) {
                try data.write(to: logURL)
            } else {
                let h = try FileHandle(forWritingTo: logURL)
                try h.seekToEnd()
                try h.write(contentsOf: data)
                try h.close()
            }
        } catch { }
    }

    static func truncate(for fileURL: URL) throws {
        let logURL = fileURL.appendingPathExtension("events.jsonl")
        if FileManager.default.fileExists(atPath: logURL.path) {
            try Data().write(to: logURL)
        }
    }

    static func logURL(for fileURL: URL) -> URL {
        fileURL.appendingPathExtension("events.jsonl")
    }
}

// MARK: - Store (single file)

@MainActor
final class ReviewStore: ObservableObject {
    @Published var source: String = ""
    @Published var comments: [Comment] = []
    @Published var statusMessage: String = ""

    let fileURL: URL
    let sidecarURL: URL
    let exportURL: URL
    let author: String
    let streamToStdout: Bool
    private var anchoredSourceHash: String = ""
    /// SHA256 of the last sidecar payload we wrote. Used to ignore our own
    /// writes when polling for external mutations.
    private var lastWrittenSidecarHash: String = ""
    private var sidecarPollTimer: DispatchSourceTimer?

    init(fileURL: URL, streamToStdout: Bool) {
        self.fileURL = fileURL
        self.sidecarURL = fileURL.appendingPathExtension("comments.json")
        let exportName = fileURL.deletingPathExtension().lastPathComponent + ".review.md"
        self.exportURL = fileURL.deletingLastPathComponent().appendingPathComponent(exportName)
        let full = NSFullUserName()
        self.author = full.isEmpty ? NSUserName() : full
        self.streamToStdout = streamToStdout
        load()
        if streamToStdout {
            // Only start polling in GUI/duplex sessions. One-shot CLI invocations
            // build a transient ReviewStore and don't need a watcher.
            startSidecarPolling()
        }
    }

    deinit {
        sidecarPollTimer?.cancel()
    }

    /// Watch the sidecar JSON for external mutations (e.g., another process
    /// running `human-review add`). Re-loads comments + re-renders when the
    /// file content's SHA differs from what we last wrote.
    private func startSidecarPolling() {
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 0.5, repeating: 0.5)
        t.setEventHandler { [weak self] in self?.checkSidecarForExternalChange() }
        t.resume()
        sidecarPollTimer = t
    }

    private func checkSidecarForExternalChange() {
        guard FileManager.default.fileExists(atPath: sidecarURL.path) else { return }
        guard let data = try? Data(contentsOf: sidecarURL) else { return }
        let h = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        if h == lastWrittenSidecarHash { return }  // our own write — ignore
        // External update — adopt it.
        do {
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            let loaded = try dec.decode(CommentFile.self, from: data)
            comments = loaded.comments.sorted { $0.createdAt < $1.createdAt }
            anchoredSourceHash = loaded.sourceHash
            lastWrittenSidecarHash = h
            statusMessage = "External update · \(comments.count) comments"
        } catch {
            statusMessage = "External sidecar change but decode failed"
        }
    }

    // MARK: I/O

    func load() {
        do {
            source = try String(contentsOf: fileURL, encoding: .utf8)
        } catch {
            source = "# Could not read \(fileURL.lastPathComponent)\n\n\(error.localizedDescription)"
        }
        anchoredSourceHash = source.sha256Prefix()
        if FileManager.default.fileExists(atPath: sidecarURL.path) {
            do {
                let data = try Data(contentsOf: sidecarURL)
                let dec = JSONDecoder()
                dec.dateDecodingStrategy = .iso8601
                let loaded = try dec.decode(CommentFile.self, from: data)
                // Sort by createdAt within thread, but list ordering doesn't matter
                // — the renderer groups by replyTo. Keep them sorted by createdAt
                // overall for stable display.
                comments = loaded.comments.sorted { $0.createdAt < $1.createdAt }
                anchoredSourceHash = loaded.sourceHash
            } catch {
                statusMessage = "Failed to load sidecar: \(error.localizedDescription)"
            }
        }
    }

    @discardableResult
    private func saveSidecar() -> Bool {
        let hash = source.sha256Prefix()
        let payload = CommentFile(
            file: fileURL.lastPathComponent,
            sourceHash: hash,
            comments: comments
        )
        do {
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try enc.encode(payload)
            try data.write(to: sidecarURL, options: .atomic)
            anchoredSourceHash = hash
            // Record what we just wrote so the poll loop doesn't echo our own write
            // back as an "external change".
            lastWrittenSidecarHash = SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }.joined()
            return true
        } catch {
            statusMessage = "Save failed: \(error.localizedDescription)"
            return false
        }
    }

    func writeInlineExport() {
        guard !comments.isEmpty else {
            try? FileManager.default.removeItem(at: exportURL)
            return
        }
        let lines = source.components(separatedBy: "\n")
        var byAnchor: [Int: [Comment]] = [:]
        for c in comments where !c.orphaned {
            byAnchor[c.anchorLine, default: []].append(c)
        }

        var insertions: [(afterLine: Int, text: String)] = []
        let df = ISO8601DateFormatter()
        df.formatOptions = [.withFullDate]

        for (start, cs) in byAnchor {
            // Find end-of-block.
            var end = start
            var inFence = false
            for i in start..<lines.count {
                let line = lines[i]
                if line.range(of: #"^\s*(```|~~~)"#, options: .regularExpression) != nil {
                    inFence.toggle()
                }
                if !inFence && line.trimmingCharacters(in: .whitespaces).isEmpty {
                    end = i - 1; break
                }
                end = i
            }

            // Group by thread (root) and render each as a callout chain.
            let roots = cs.filter { $0.replyTo == nil }
            var block = ""
            for root in roots.sorted(by: { $0.createdAt < $1.createdAt }) {
                let allInThread = self.thread(rootedAt: root.id)
                let resolvedMark = root.resolved ? " · ✓ resolved" : ""
                block += "\n> [!review]\(resolvedMark)\n"
                for (i, c) in allInThread.enumerated() {
                    let when = df.string(from: c.createdAt)
                    let prefix = i == 0 ? "" : "→ "
                    let bodyLines = c.body
                        .components(separatedBy: "\n")
                        .map { "> \($0)" }
                        .joined(separator: "\n")
                    block += "> \(prefix)**\(c.author)** · \(when)\n\(bodyLines)\n"
                    if i < allInThread.count - 1 { block += ">\n" }
                }
            }
            insertions.append((afterLine: end, text: block))
        }

        var out = lines
        for ins in insertions.sorted(by: { $0.afterLine > $1.afterLine }) {
            let payload = ins.text.components(separatedBy: "\n")
            out.insert(contentsOf: payload, at: ins.afterLine + 1)
        }

        try? out.joined(separator: "\n").write(to: exportURL, atomically: true, encoding: .utf8)
    }

    private func persist() {
        saveSidecar()
        writeInlineExport()
    }

    // MARK: Thread helpers

    /// Walk replyTo upward until we reach a comment with replyTo == nil.
    func rootId(of id: UUID) -> UUID? {
        var current = comments.first { $0.id == id }
        var visited: Set<UUID> = []
        while let c = current, let parent = c.replyTo {
            if visited.contains(c.id) { return nil }   // cycle guard
            visited.insert(c.id)
            current = comments.first { $0.id == parent }
        }
        return current?.id
    }

    /// All comments in the thread rooted at `rootId`, in chronological order
    /// (root first).
    func thread(rootedAt rootId: UUID) -> [Comment] {
        guard let root = comments.first(where: { $0.id == rootId }) else { return [] }
        var result = [root]
        var frontier: [UUID] = [rootId]
        var safety = 0
        while !frontier.isEmpty && safety < 10_000 {
            safety += 1
            let next = frontier.removeFirst()
            let children = comments.filter { $0.replyTo == next }
            result.append(contentsOf: children)
            frontier.append(contentsOf: children.map { $0.id })
        }
        return result.sorted { $0.createdAt < $1.createdAt }
    }

    var threadRoots: [Comment] {
        comments.filter { $0.replyTo == nil }
    }
    var activeThreadRoots: [Comment] {
        threadRoots.filter { !$0.resolved }
    }

    // MARK: Mutations

    /// Add a new comment. If `replyTo` is set, anchorLine/anchorText are
    /// copied from the thread root, and replying to a resolved thread auto-
    /// reopens it. Returns the new comment.
    @discardableResult
    func addComment(line: Int, anchorText: String, body: String,
                    replyTo: UUID? = nil, author: String? = nil) -> Comment? {
        let who = author ?? self.author
        var c: Comment
        if let parentId = replyTo {
            guard let rootId = rootId(of: parentId),
                  let root = comments.first(where: { $0.id == rootId }) else {
                statusMessage = "Reply target not found: \(parentId)"
                return nil
            }
            c = Comment(replyTo: parentId, anchorLine: root.anchorLine,
                        anchorText: root.anchorText, body: body,
                        author: who, resolved: false, orphaned: root.orphaned)
            // Auto-reopen on reply.
            var reopened = false
            if root.resolved {
                if let i = comments.firstIndex(where: { $0.id == root.id }) {
                    comments[i].resolved = false
                    reopened = true
                }
            }
            comments.append(c)
            persist()
            emit(event: "added", comment: c)
            if reopened, let r = comments.first(where: { $0.id == root.id }) {
                emit(event: "reopened", comment: r)
            }
            return c
        } else {
            let snippet = String(anchorText.prefix(80))
            c = Comment(replyTo: nil, anchorLine: line, anchorText: snippet,
                        body: body, author: who)
            comments.append(c)
            persist()
            emit(event: "added", comment: c)
            return c
        }
    }

    func editComment(_ id: UUID, body: String) {
        guard let idx = comments.firstIndex(where: { $0.id == id }) else { return }
        comments[idx].body = body
        persist()
        emit(event: "edited", comment: comments[idx])
    }

    /// Delete a single comment. If it's a thread root, the whole thread
    /// (and any replies) is removed.
    func deleteComment(_ id: UUID) {
        guard let target = comments.first(where: { $0.id == id }) else { return }
        if target.replyTo == nil {
            // Root — remove whole thread.
            let toRemove = thread(rootedAt: id).map { $0.id }
            comments.removeAll { toRemove.contains($0.id) }
        } else {
            comments.removeAll { $0.id == id }
        }
        persist()
        emit(event: "deleted", comment: target)
    }

    /// Resolve the thread that contains `id` (any descendant id works).
    func resolveThread(_ id: UUID) {
        guard let rootId = rootId(of: id) else { return }
        guard let i = comments.firstIndex(where: { $0.id == rootId }) else { return }
        if comments[i].resolved { return }   // idempotent
        comments[i].resolved = true
        persist()
        emit(event: "resolved", comment: comments[i])
    }

    /// Reopen the thread that contains `id` (any descendant id works).
    func reopenThread(_ id: UUID) {
        guard let rootId = rootId(of: id) else { return }
        guard let i = comments.firstIndex(where: { $0.id == rootId }) else { return }
        if !comments[i].resolved { return }
        comments[i].resolved = false
        persist()
        emit(event: "reopened", comment: comments[i])
    }

    // MARK: Reload (smart re-anchor)

    @discardableResult
    func reload() -> ReanchorStats {
        do {
            source = try String(contentsOf: fileURL, encoding: .utf8)
        } catch {
            statusMessage = "Reload failed: \(error.localizedDescription)"
            return ReanchorStats(unchanged: 0, relocated: 0, orphaned: 0)
        }

        let diskHash = source.sha256Prefix()
        if diskHash == anchoredSourceHash {
            let stats = ReanchorStats(unchanged: threadRoots.count, relocated: 0, orphaned: 0)
            statusMessage = "Reloaded — source unchanged"
            emitReloaded(stats)
            return stats
        }

        var unchanged = 0, relocated = 0, orphans = 0
        let lines = source.components(separatedBy: "\n")

        // Re-anchor only thread roots. Replies inherit their root's anchor.
        for i in 0..<comments.count {
            guard comments[i].replyTo == nil else { continue }
            let original = comments[i].anchorLine
            let probe = comments[i].anchorText
                .components(separatedBy: "\n").first?
                .trimmingCharacters(in: .whitespaces) ?? ""
            guard !probe.isEmpty else { orphans += 1; comments[i].orphaned = true; continue }

            let hits = lines.enumerated().compactMap { (idx, line) -> Int? in
                line.trimmingCharacters(in: .whitespaces).hasPrefix(probe) ? idx : nil
            }
            guard let best = hits.min(by: { abs($0 - original) < abs($1 - original) }) else {
                comments[i].orphaned = true
                orphans += 1
                continue
            }
            var start = best
            while start > 0 && !lines[start - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                start -= 1
            }
            comments[i].orphaned = false
            if start == original { unchanged += 1 }
            else { comments[i].anchorLine = start; relocated += 1 }
        }

        // Sync replies' anchorLine to their root (cosmetic, for debugging).
        let rootMap: [UUID: Comment] = Dictionary(uniqueKeysWithValues: comments
            .filter { $0.replyTo == nil }.map { ($0.id, $0) })
        for i in 0..<comments.count {
            if comments[i].replyTo != nil,
               let rid = rootId(of: comments[i].id),
               let root = rootMap[rid] {
                comments[i].anchorLine = root.anchorLine
                comments[i].orphaned = root.orphaned
            }
        }

        saveSidecar()
        writeInlineExport()
        let stats = ReanchorStats(unchanged: unchanged, relocated: relocated, orphaned: orphans)
        statusMessage = "Reloaded · \(unchanged) unchanged · \(relocated) relocated · \(orphans) orphaned"
        emitReloaded(stats)
        return stats
    }

    private func emitReloaded(_ stats: ReanchorStats) {
        let ev = StreamEvent(
            event: "reloaded", timestamp: Date(), file: fileURL.path,
            comment: nil, files: nil, reanchor: stats
        )
        // Always append to per-file event log so headless agents see it.
        EventLog.append(ev, for: fileURL)
        if streamToStdout { emitEvent(ev) }
    }

    private func emit(event: String, comment: Comment?) {
        let ev = StreamEvent(
            event: event, timestamp: Date(), file: fileURL.path,
            comment: comment, files: nil, reanchor: nil
        )
        EventLog.append(ev, for: fileURL)
        if streamToStdout { emitEvent(ev) }
    }
}

// MARK: - Session (multi-file)

@MainActor
final class ReviewSession: ObservableObject {
    @Published var currentIndex: Int = 0
    @Published var urls: [URL]
    let stream: Bool
    let emitOnExit: Bool
    var suppressExitEvent: Bool = false
    private var stores: [URL: ReviewStore] = [:]

    init(urls: [URL], stream: Bool, emitOnExit: Bool) {
        self.urls = urls
        self.stream = stream
        self.emitOnExit = emitOnExit
        for url in urls {
            stores[url] = ReviewStore(fileURL: url, streamToStdout: stream)
        }
        if stream { emitSessionStart() }
    }

    func store(at index: Int) -> ReviewStore { stores[urls[index]]! }
    func store(for url: URL) -> ReviewStore? { stores[url] }
    var current: ReviewStore { stores[urls[currentIndex]]! }
    var totalFiles: Int { urls.count }
    var canGoNext: Bool { currentIndex < urls.count - 1 }
    var canGoPrev: Bool { currentIndex > 0 }

    func next() { if canGoNext { currentIndex += 1 } }
    func previous() { if canGoPrev { currentIndex -= 1 } }

    @discardableResult
    func openFile(_ url: URL) -> Int {
        if let i = urls.firstIndex(of: url) { return i }
        urls.append(url)
        stores[url] = ReviewStore(fileURL: url, streamToStdout: stream)
        // Per-file gui_opened so a brand-new file's watcher fires.
        let perFile = StreamEvent(
            event: "gui_opened", timestamp: Date(), file: url.path,
            comment: nil,
            files: [FileSummary(file: url.path, comments: stores[url]?.comments ?? [])],
            reanchor: nil
        )
        EventLog.append(perFile, for: url)
        return urls.count - 1
    }

    func focusFile(_ url: URL) -> Bool {
        guard let i = urls.firstIndex(of: url) else { return false }
        currentIndex = i
        return true
    }

    private func emitSessionStart() {
        emitEvent(StreamEvent(
            event: "session_start", timestamp: Date(), file: nil,
            comment: nil, files: fileSummaries(), reanchor: nil
        ))
        // Per-file marker so `human-review watch FILE` sees a GUI come up.
        for url in urls {
            let perFile = StreamEvent(
                event: "gui_opened", timestamp: Date(), file: url.path,
                comment: nil,
                files: [FileSummary(file: url.path, comments: stores[url]?.comments ?? [])],
                reanchor: nil
            )
            EventLog.append(perFile, for: url)
        }
    }

    func emitExit() {
        guard emitOnExit, !suppressExitEvent else { return }
        suppressExitEvent = true
        emitEvent(StreamEvent(
            event: "exit", timestamp: Date(), file: nil,
            comment: nil, files: fileSummaries(), reanchor: nil
        ))
        // Per-file marker so `human-review wait FILE --exit` can fire.
        for url in urls {
            let perFile = StreamEvent(
                event: "gui_closed", timestamp: Date(), file: url.path,
                comment: nil,
                files: [FileSummary(file: url.path, comments: stores[url]?.comments ?? [])],
                reanchor: nil
            )
            EventLog.append(perFile, for: url)
        }
    }

    func emitFileEvent(_ event: String, file: URL) {
        guard stream else { return }
        emitEvent(StreamEvent(
            event: event, timestamp: Date(), file: file.path,
            comment: nil, files: nil, reanchor: nil
        ))
    }

    func emitCommandError(_ raw: String, _ reason: String) {
        guard stream else { return }
        let payload: [String: Any] = [
            "event": "command_error",
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "reason": reason, "raw": raw
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let s = String(data: data, encoding: .utf8) {
            print(s); fflush(stdout)
        }
    }

    private func fileSummaries() -> [FileSummary] {
        urls.map { FileSummary(file: $0.path, comments: stores[$0]?.comments ?? []) }
    }
}

// MARK: - Stdin command protocol

@MainActor
final class CommandRouter {
    weak var session: ReviewSession?

    func start() {
        if isatty(fileno(stdin)) != 0 { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            while let line = Swift.readLine(strippingNewline: true) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { continue }
                DispatchQueue.main.async { self.handle(trimmed) }
            }
        }
    }

    func handle(_ raw: String) {
        guard let session = session else { return }
        guard let data = raw.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let cmd = obj["cmd"] as? String else {
            session.emitCommandError(raw, "could not parse JSON command")
            return
        }
        do {
            switch cmd {
            case "ping":
                session.emitFileEvent("pong", file: URL(fileURLWithPath: ""))
            case "add":
                let store = try resolveStore(session, obj)
                let body = (obj["body"] as? String) ?? ""
                guard !body.isEmpty else { throw CmdErr.missing("body") }
                let author = (obj["author"] as? String) ?? "agent"
                let replyTo = (obj["replyTo"] as? String).flatMap { UUID(uuidString: $0) }
                if replyTo != nil {
                    store.addComment(line: 0, anchorText: "", body: body,
                                     replyTo: replyTo, author: author)
                } else {
                    guard let line = obj["line"] as? Int else { throw CmdErr.missing("line") }
                    let (start, text) = CLI.nearestBlock(in: store.source, around: max(0, line - 1))
                    store.addComment(line: start, anchorText: text, body: body,
                                     replyTo: nil, author: author)
                }
            case "resolve":
                let store = try resolveStore(session, obj)
                guard let idStr = obj["id"] as? String,
                      let id = UUID(uuidString: idStr) else { throw CmdErr.missing("id") }
                store.resolveThread(id)
            case "reopen":
                let store = try resolveStore(session, obj)
                guard let idStr = obj["id"] as? String,
                      let id = UUID(uuidString: idStr) else { throw CmdErr.missing("id") }
                store.reopenThread(id)
            case "delete":
                let store = try resolveStore(session, obj)
                guard let idStr = obj["id"] as? String,
                      let id = UUID(uuidString: idStr) else { throw CmdErr.missing("id") }
                store.deleteComment(id)
            case "reload":
                try resolveStore(session, obj).reload()
            case "open":
                guard let path = obj["file"] as? String else { throw CmdErr.missing("file") }
                let url = CLI.resolveURL(path)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw CmdErr.notInSession(path)
                }
                session.openFile(url)
                session.emitFileEvent("opened", file: url)
            case "focus":
                guard let path = obj["file"] as? String else { throw CmdErr.missing("file") }
                let url = CLI.resolveURL(path)
                if session.focusFile(url) {
                    session.emitFileEvent("focused", file: url)
                } else {
                    throw CmdErr.notInSession(path)
                }
            default:
                throw CmdErr.unknown(cmd)
            }
        } catch { session.emitCommandError(raw, "\(error)") }
    }

    enum CmdErr: Error, CustomStringConvertible {
        case missing(String), notInSession(String), unknown(String)
        var description: String {
            switch self {
            case .missing(let f): return "missing '\(f)'"
            case .notInSession(let p): return "file not in session: \(p)"
            case .unknown(let c): return "unknown cmd: \(c)"
            }
        }
    }

    private func resolveStore(_ session: ReviewSession, _ obj: [String: Any]) throws -> ReviewStore {
        guard let path = obj["file"] as? String else { throw CmdErr.missing("file") }
        let url = CLI.resolveURL(path)
        guard let store = session.store(for: url) else { throw CmdErr.notInSession(path) }
        return store
    }
}

// MARK: - WebView bridge

final class WebViewCoordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    weak var store: ReviewStore?
    var onReady: (() -> Void)?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let dict = message.body as? [String: Any], let type = dict["type"] as? String else { return }
        switch type {
        case "ready":
            onReady?()
        case "addComment":
            guard let body = dict["body"] as? String else { return }
            let replyTo = (dict["replyTo"] as? String).flatMap { UUID(uuidString: $0) }
            Task { @MainActor in
                if replyTo != nil {
                    self.store?.addComment(line: 0, anchorText: "", body: body, replyTo: replyTo, author: nil)
                } else {
                    guard let line = dict["line"] as? Int,
                          let text = dict["text"] as? String else { return }
                    self.store?.addComment(line: line, anchorText: text, body: body,
                                           replyTo: nil, author: nil)
                }
            }
        case "deleteComment":
            if let idStr = dict["id"] as? String, let id = UUID(uuidString: idStr) {
                Task { @MainActor in self.store?.deleteComment(id) }
            }
        case "resolveThread":
            if let idStr = dict["id"] as? String, let id = UUID(uuidString: idStr) {
                Task { @MainActor in self.store?.resolveThread(id) }
            }
        case "reopenThread":
            if let idStr = dict["id"] as? String, let id = UUID(uuidString: idStr) {
                Task { @MainActor in self.store?.reopenThread(id) }
            }
        default:
            break
        }
    }
}

struct MarkdownWebView: NSViewRepresentable {
    @ObservedObject var store: ReviewStore

    func makeCoordinator() -> WebViewCoordinator {
        let c = WebViewCoordinator()
        c.store = store
        return c
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "swift")
        config.userContentController = controller
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")

        if let url = Bundle.module.url(forResource: "viewer", withExtension: "html") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.loadHTMLString("<h1>viewer.html missing</h1>", baseURL: nil)
        }

        context.coordinator.onReady = { [weak webView] in
            guard let webView = webView else { return }
            Self.pushState(webView: webView, store: store)
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.store = store
        Self.pushState(webView: webView, store: store)
    }

    static func pushState(webView: WKWebView, store: ReviewStore) {
        let payload = ViewerPayload(source: store.source, comments: store.comments)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(payload),
              let jsonStr = String(data: data, encoding: .utf8) else { return }
        let js = "if (window.hr) { window.hr.applyState(\(jsonStr)); }"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }
}

// MARK: - Window views

struct FileReviewView: View {
    @ObservedObject var store: ReviewStore

    var body: some View {
        VStack(spacing: 0) {
            MarkdownWebView(store: store)
            Divider()
            HStack {
                Text(store.statusMessage)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Text("\(store.threadRoots.count) thread\(store.threadRoots.count == 1 ? "" : "s")")
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
    }
}

struct HeaderBar: View {
    @ObservedObject var session: ReviewSession

    private var activeCount: Int { session.current.activeThreadRoots.count }

    var body: some View {
        HStack(spacing: 10) {
            Text("\(session.currentIndex + 1) / \(session.totalFiles)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.gray.opacity(0.12))
                .cornerRadius(4)
            Text(session.urls[session.currentIndex].lastPathComponent)
                .font(.headline)
                .lineLimit(1).truncationMode(.middle)
            if activeCount > 0 {
                Text("● \(activeCount) active")
                    .font(.caption.monospaced())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.yellow.opacity(0.25))
                    .cornerRadius(4)
                    .help("\(activeCount) active thread\(activeCount == 1 ? "" : "s") — press n / N to navigate")
            }
            Spacer()
            Button(action: { session.previous() }) { Image(systemName: "chevron.left") }
                .disabled(!session.canGoPrev)
                .help("Previous file (⌘[)")
            if session.canGoNext {
                Button(action: { session.next() }) { Image(systemName: "chevron.right") }
                    .help("Next file (⌘])")
            } else {
                Button(action: { NSApp.terminate(nil) }) {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                        Text("Exit")
                    }
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .tint(.green)
                .help("Finish review & exit (⌘Return)")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.bar)
    }
}

struct SessionWindow: View {
    @ObservedObject var session: ReviewSession

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar(session: session)
            Divider()
            FileReviewView(store: session.current)
                .id(session.currentIndex)
        }
    }
}

// MARK: - CLI

enum CLI {
    static func main(_ argv: [String]) -> Int32 {
        let args = Array(argv.dropFirst())
        guard !args.isEmpty else { printUsage(); return 2 }

        let subcommands: Set<String> = [
            "add", "list", "export", "delete", "resolve", "reopen", "reload",
            "watch", "wait", "threads", "get", "prune",
            "help", "-h", "--help"
        ]
        if subcommands.contains(args[0]) {
            switch args[0] {
            case "help", "-h", "--help": printUsage(); return 0
            case "add":     return cmdAdd(Array(args.dropFirst()))
            case "list":    return cmdList(Array(args.dropFirst()))
            case "export":  return cmdExport(Array(args.dropFirst()))
            case "delete":  return cmdDelete(Array(args.dropFirst()))
            case "resolve": return cmdResolve(Array(args.dropFirst()))
            case "reopen":  return cmdReopen(Array(args.dropFirst()))
            case "reload":  return cmdReload(Array(args.dropFirst()))
            case "watch":   return cmdWatch(Array(args.dropFirst()))
            case "wait":    return cmdWait(Array(args.dropFirst()))
            case "threads": return cmdThreads(Array(args.dropFirst()))
            case "get":     return cmdGet(Array(args.dropFirst()))
            case "prune":   return cmdPrune(Array(args.dropFirst()))
            default: break
            }
        }

        var stream = true
        var emitOnExit = true
        var filePaths: [String] = []
        for a in args {
            switch a {
            case "--no-stream":         stream = false
            case "--no-emit-on-exit":   emitOnExit = false
            case "--stream":            stream = true
            default:
                if a.hasPrefix("--") {
                    FileHandle.standardError.write("unknown flag: \(a)\n".data(using: .utf8)!)
                    return 2
                }
                filePaths.append(a)
            }
        }
        if filePaths.isEmpty { printUsage(); return 2 }

        var urls: [URL] = []
        for p in filePaths {
            let url = resolveURL(p)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileHandle.standardError.write("human-review: file not found: \(p)\n".data(using: .utf8)!)
                return 1
            }
            urls.append(url)
        }

        MainActor.assumeIsolated {
            let session = ReviewSession(urls: urls, stream: stream, emitOnExit: emitOnExit)
            launchApp(session: session)
        }
        return 0
    }

    static func printUsage() {
        let msg = """
        human-review · GitHub-style review for local markdown files
                       Native CLI for agents — every interaction is a shell command.

        ─── Concept ────────────────────────────────────────────────────────────────────
          A *comment* anchors to a markdown block. A *thread* is a comment + replies.
          A thread is **active** (resolved=false) or **settled** (resolved=true).
          Replying to a settled thread auto-reopens it. Everything is just a comment;
          there is no separate "flag" kind.

          Per source FILE.md, three sidecars are kept atomically in sync:
            FILE.md.comments.json    canonical state (read by everyone)
            FILE.md.events.jsonl     append-only event log (tail this for live updates)
            FILE.review.md           inline-annotated markdown copy

          All mutations — from the GUI window, from `human-review add`, from any other
          process — write to all three. A running GUI auto-reloads when an external
          process mutates the sidecar.

        ─── GUI mode (for the human) ───────────────────────────────────────────────────
          human-review FILE.md [FILE2.md ...]      Open review window
          --no-stream                              Disable live events on stdout
          --no-emit-on-exit                        Disable final exit-summary event

        Keyboard inside the window:
          ↑ / ↓  (or k / j)   Move focus between blocks
          Enter               Open composer (reply if block has active thread, else new)
          n / N               Jump to next / previous ACTIVE thread (wraps)
          Tab                 In composer: submit + auto-advance focus
          ⌘ Enter             In composer: submit (alternative)
          Esc                 Cancel open composer
          ⌘ ] / ⌘ [           Next / previous file
          ⌘ R                 Reload source from disk (smart re-anchor)
          ⌘ W or ✓ Exit       Close window (fires `exit` event)

        ─── Agent CLI (for an LLM or a shell script) ──────────────────────────────────
        Mutate. Each prints the resulting record (or {reanchor}) as JSON on stdout
        and appends one line to FILE.md.events.jsonl.

          human-review add     FILE.md --line N    --body "TEXT" [--author NAME]
          human-review add     FILE.md --reply-to UUID --body "TEXT" [--author NAME]
          human-review resolve FILE.md --id UUID
          human-review reopen  FILE.md --id UUID
          human-review delete  FILE.md --id UUID
          human-review reload  FILE.md
          human-review export  FILE.md

        Read.

          human-review list    FILE.md                  All comments as a JSON array
          human-review threads FILE.md [--active|--settled]   Thread roots + reply counts
          human-review get     FILE.md --id UUID        One comment as JSON

        Subscribe to live events (tails FILE.md.events.jsonl, blocks):

          human-review watch   FILE.md [FILE2 ...] [--from-start] [--types LIST]
              Defaults: emit every new event from now on. `--from-start` replays.
              `--types added,resolved,...` filters event types.

        Block-and-wait helpers (exit 0 on match, 124 on timeout):

          human-review wait    FILE.md --reply-to UUID  [--from-author NAME] [--timeout S]
              Blocks until any reply lands in the thread containing UUID.
              Prints the matching event JSON on stdout.

          human-review wait    FILE.md --resolve UUID                  [--timeout S]
              Blocks until that thread is marked resolved.

          human-review wait    FILE.md --exit                          [--timeout S]
              Blocks until a GUI session closes for that file.

        Housekeeping:

          human-review prune   FILE.md                  Truncate events.jsonl
          human-review --help                           This text

        ─── Complete agent flow in pure shell ──────────────────────────────────────────
          # Open a GUI for the human in the background
          human-review notes.md &

          # Post an inline review note, capture the thread root id
          ROOT=$(human-review add notes.md --line 42 \\
                   --body "verify the claim about X" | jq -r '.id')

          # Block until the human replies (up to 10 minutes)
          REPLY=$(human-review wait notes.md --reply-to "$ROOT" --timeout 600)
          echo "human said: $(echo "$REPLY" | jq -r '.comment.body')"

          # Send a follow-up and resolve
          human-review add notes.md --reply-to "$ROOT" --body "thanks, addressed."
          human-review resolve notes.md --id "$ROOT"

        ─── Optional duplex stdin (when you DO have a long-lived parent process) ───────
        If you spawn a GUI yourself and pipe JSONL into its stdin, the same
        commands are accepted as stdin protocol — see `--types` and `wait`-style
        usage in the watch subcommand for the equivalent shell-native flow.

        Stdin commands (auto-active when stdin is piped):
          {"cmd":"add","file":"…","line":N,"body":"…"} | {"cmd":"add","replyTo":"UUID",…}
          {"cmd":"resolve","file":"…","id":"UUID"} | {"cmd":"reopen",…} | {"cmd":"delete",…}
          {"cmd":"reload",…} | {"cmd":"open",…} | {"cmd":"focus",…} | {"cmd":"ping"}

        ─── Event shapes ───────────────────────────────────────────────────────────────
        Events in FILE.md.events.jsonl (and on GUI stdout):
          gui_opened    {file, files:[{file, comments[]}]}    GUI started for that file
          gui_closed    {file, files:[{file, comments[]}]}    GUI exited for that file
          added         {file, comment}            new thread root OR reply (check replyTo)
          edited        {file, comment}            body changed
          deleted       {file, comment}            comment removed (root → whole thread)
          resolved      {file, comment}            thread root settled
          reopened      {file, comment}            thread root un-settled (manual or auto)
          reloaded      {file, reanchor:{unchanged,relocated,orphaned}}

        Comment record:
          {id:"UUID", replyTo:"UUID"|null, anchorLine:N0 (0-indexed),
           anchorText:"first 80 chars of block", body:"…", author:"…",
           createdAt:"ISO8601", resolved:bool, orphaned:bool}

        """
        FileHandle.standardError.write(msg.data(using: .utf8)!)
    }

    @MainActor
    static func launchApp(session: ReviewSession) {
        let app = NSApplication.shared
        let delegate = AppDelegate(session: session)
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    // MARK: - Subcommands

    static func cmdAdd(_ args: [String]) -> Int32 {
        guard let file = args.first(where: { !$0.hasPrefix("--") }) else {
            FileHandle.standardError.write("missing <file>\n".data(using: .utf8)!); return 2
        }
        let body = flagValue(args, "--body") ?? ""
        guard !body.isEmpty else {
            FileHandle.standardError.write("--body is required\n".data(using: .utf8)!); return 2
        }
        let author = flagValue(args, "--author")
        let url = resolveURL(file)
        guard FileManager.default.fileExists(atPath: url.path) else {
            FileHandle.standardError.write("file not found: \(file)\n".data(using: .utf8)!); return 1
        }
        return MainActor.assumeIsolated {
            // One-shot CLI invocation — don't double-emit on stdout; we'll print
            // the resulting comment JSON ourselves below.
            let store = ReviewStore(fileURL: url, streamToStdout: false)
            let result: Comment?
            if let replyStr = flagValue(args, "--reply-to"), let replyId = UUID(uuidString: replyStr) {
                result = store.addComment(line: 0, anchorText: "", body: body, replyTo: replyId, author: author)
            } else {
                guard let lineStr = flagValue(args, "--line"), let line = Int(lineStr) else {
                    FileHandle.standardError.write("--line is required (or --reply-to)\n".data(using: .utf8)!)
                    return 2
                }
                let (start, text) = nearestBlock(in: store.source, around: max(0, line - 1))
                result = store.addComment(line: start, anchorText: text, body: body, replyTo: nil, author: author)
            }
            guard let c = result else {
                FileHandle.standardError.write("add failed\n".data(using: .utf8)!); return 1
            }
            printJSON(c)
            return 0
        }
    }

    /// Pretty-print any Encodable as JSON to stdout.
    static func printJSON<T: Encodable>(_ v: T) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(v), let s = String(data: data, encoding: .utf8) {
            print(s)
        }
    }

    static func cmdList(_ args: [String]) -> Int32 {
        guard let file = args.first(where: { !$0.hasPrefix("--") }) else {
            FileHandle.standardError.write("missing <file>\n".data(using: .utf8)!); return 2
        }
        let url = resolveURL(file)
        guard FileManager.default.fileExists(atPath: url.path) else {
            FileHandle.standardError.write("file not found: \(file)\n".data(using: .utf8)!); return 1
        }
        return MainActor.assumeIsolated {
            let store = ReviewStore(fileURL: url, streamToStdout: false)
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? enc.encode(store.comments), let s = String(data: data, encoding: .utf8) {
                print(s)
            }
            return 0
        }
    }

    static func cmdExport(_ args: [String]) -> Int32 {
        guard let file = args.first(where: { !$0.hasPrefix("--") }) else {
            FileHandle.standardError.write("missing <file>\n".data(using: .utf8)!); return 2
        }
        let url = resolveURL(file)
        guard FileManager.default.fileExists(atPath: url.path) else {
            FileHandle.standardError.write("file not found: \(file)\n".data(using: .utf8)!); return 1
        }
        return MainActor.assumeIsolated {
            let store = ReviewStore(fileURL: url, streamToStdout: false)
            store.writeInlineExport()
            print(store.exportURL.path)
            return 0
        }
    }

    static func cmdReload(_ args: [String]) -> Int32 {
        guard let file = args.first(where: { !$0.hasPrefix("--") }) else {
            FileHandle.standardError.write("missing <file>\n".data(using: .utf8)!); return 2
        }
        let url = resolveURL(file)
        guard FileManager.default.fileExists(atPath: url.path) else {
            FileHandle.standardError.write("file not found: \(file)\n".data(using: .utf8)!); return 1
        }
        return MainActor.assumeIsolated {
            let store = ReviewStore(fileURL: url, streamToStdout: false)
            let stats = store.reload()
            printJSON(stats)
            return 0
        }
    }

    static func cmdDelete(_ args: [String]) -> Int32 {
        mutateAndPrintResult(args) { @MainActor store, id in
            let target = store.comments.first(where: { $0.id == id })
            store.deleteComment(id)
            return target   // return the deleted comment as it was
        }
    }
    static func cmdResolve(_ args: [String]) -> Int32 {
        mutateAndPrintResult(args) { @MainActor store, id in
            store.resolveThread(id)
            if let rid = store.rootId(of: id) {
                return store.comments.first(where: { $0.id == rid })
            }
            return nil
        }
    }
    static func cmdReopen(_ args: [String]) -> Int32 {
        mutateAndPrintResult(args) { @MainActor store, id in
            store.reopenThread(id)
            if let rid = store.rootId(of: id) {
                return store.comments.first(where: { $0.id == rid })
            }
            return nil
        }
    }

    private static func mutateAndPrintResult(
        _ args: [String],
        _ action: @MainActor @escaping (ReviewStore, UUID) -> Comment?
    ) -> Int32 {
        guard let file = args.first(where: { !$0.hasPrefix("--") }) else {
            FileHandle.standardError.write("missing <file>\n".data(using: .utf8)!); return 2
        }
        guard let idStr = flagValue(args, "--id"), let id = UUID(uuidString: idStr) else {
            FileHandle.standardError.write("--id <uuid> required\n".data(using: .utf8)!); return 2
        }
        let url = resolveURL(file)
        guard FileManager.default.fileExists(atPath: url.path) else {
            FileHandle.standardError.write("file not found: \(file)\n".data(using: .utf8)!); return 1
        }
        return MainActor.assumeIsolated {
            let store = ReviewStore(fileURL: url, streamToStdout: false)
            let result = action(store, id)
            if let c = result { printJSON(c) } else { print("null") }
            return 0
        }
    }

    // MARK: - watch / wait / threads / get / prune

    /// Tail one or more events.jsonl files; emit each new event to stdout as JSONL.
    /// Defaults: from-now (not replay), all event types. --from-start replays from line 1.
    /// --types=a,b,c filters event types.
    static func cmdWatch(_ args: [String]) -> Int32 {
        let files = args.filter { !$0.hasPrefix("--") && !($0 == typesValue(args)) }
        guard !files.isEmpty else {
            FileHandle.standardError.write("usage: human-review watch FILE.md [FILE2.md ...] [--from-start] [--types added,resolved,...]\n".data(using: .utf8)!)
            return 2
        }
        let fromStart = args.contains("--from-start")
        let typesFilter: Set<String>? = typesValue(args).map { Set($0.split(separator: ",").map(String.init)) }

        let urls = files.map { resolveURL($0) }
        let logPaths = urls.map { EventLog.logURL(for: $0).path }
        // Ensure each log file exists so `tail -F` doesn't bail out.
        for p in logPaths where !FileManager.default.fileExists(atPath: p) {
            FileManager.default.createFile(atPath: p, contents: nil)
        }

        return tailAndFilter(logPaths: logPaths, fromStart: fromStart, typesFilter: typesFilter,
                             stopOn: nil)
    }

    /// Block until a matching event lands. Mutually-exclusive modes:
    ///   --reply-to UUID      first reply (any author) in that thread
    ///   --resolve   UUID     thread is resolved
    ///   --exit               GUI closes for that file
    /// Prints the full matching event JSON on stdout and exits 0.
    /// On --timeout T (seconds): exits 124 with no output.
    static func cmdWait(_ args: [String]) -> Int32 {
        guard let file = args.first(where: { !$0.hasPrefix("--") }) else {
            FileHandle.standardError.write("usage: human-review wait FILE.md (--reply-to UUID | --resolve UUID | --exit) [--timeout S] [--from-start]\n".data(using: .utf8)!)
            return 2
        }
        let replyTo  = flagValue(args, "--reply-to")
        let resolve  = flagValue(args, "--resolve")
        let waitExit = args.contains("--exit")
        let fromAuthor = flagValue(args, "--from-author")
        let timeout = flagValue(args, "--timeout").flatMap { Double($0) }
        let fromStart = args.contains("--from-start")

        let modes = [replyTo != nil, resolve != nil, waitExit].filter { $0 }.count
        if modes != 1 {
            FileHandle.standardError.write("exactly one of --reply-to, --resolve, --exit is required\n".data(using: .utf8)!)
            return 2
        }
        let url = resolveURL(file)
        let logPath = EventLog.logURL(for: url).path
        if !FileManager.default.fileExists(atPath: logPath) {
            FileManager.default.createFile(atPath: logPath, contents: nil)
        }

        // Build predicate. For --reply-to, we discover thread membership as we go.
        var threadIds: Set<String> = Set(replyTo.map { [$0] } ?? [])

        let predicate: (String) -> Bool = { line in
            guard let data = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let ev = obj["event"] as? String else { return false }

            if let target = resolve {
                return ev == "resolved" && (obj["comment"] as? [String: Any])?["id"] as? String == target
            }
            if waitExit {
                return ev == "gui_closed"
            }
            // reply-to mode
            guard ev == "added", let c = obj["comment"] as? [String: Any] else { return false }
            let parent = c["replyTo"] as? String
            let id = c["id"] as? String
            // Track thread membership: any descendant whose replyTo ∈ threadIds joins.
            if let p = parent, threadIds.contains(p), let i = id { threadIds.insert(i) }
            // Match: any reply whose parent ∈ threadIds, optionally filtered by author.
            if let p = parent, threadIds.contains(p) {
                if let want = fromAuthor, (c["author"] as? String) != want { return false }
                return true
            }
            return false
        }

        return tailAndFilter(
            logPaths: [logPath], fromStart: fromStart, typesFilter: nil,
            stopOn: predicate, timeout: timeout,
            printOnly: { line in true }
        )
    }

    /// List thread roots for a file. Defaults: all roots. --active / --settled filter.
    static func cmdThreads(_ args: [String]) -> Int32 {
        guard let file = args.first(where: { !$0.hasPrefix("--") }) else {
            FileHandle.standardError.write("usage: human-review threads FILE.md [--active|--settled]\n".data(using: .utf8)!)
            return 2
        }
        let url = resolveURL(file)
        guard FileManager.default.fileExists(atPath: url.path) else {
            FileHandle.standardError.write("file not found: \(file)\n".data(using: .utf8)!); return 1
        }
        let onlyActive = args.contains("--active")
        let onlySettled = args.contains("--settled")
        return MainActor.assumeIsolated {
            let store = ReviewStore(fileURL: url, streamToStdout: false)
            var roots = store.threadRoots
            if onlyActive  { roots = roots.filter { !$0.resolved } }
            if onlySettled { roots = roots.filter {  $0.resolved } }

            // Augment each with replyCount
            let replyCounts: [UUID: Int] = Dictionary(grouping: store.comments.filter { $0.replyTo != nil },
                                                       by: { store.rootId(of: $0.id) ?? $0.id })
                .mapValues { $0.count }

            struct ThreadSummary: Encodable {
                let id: String
                let anchorLine: Int
                let anchorText: String
                let body: String
                let author: String
                let createdAt: Date
                let resolved: Bool
                let orphaned: Bool
                let replyCount: Int
            }

            let summaries = roots.map { r in
                ThreadSummary(
                    id: r.id.uuidString, anchorLine: r.anchorLine,
                    anchorText: r.anchorText, body: r.body, author: r.author,
                    createdAt: r.createdAt, resolved: r.resolved,
                    orphaned: r.orphaned, replyCount: replyCounts[r.id] ?? 0
                )
            }
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? enc.encode(summaries), let s = String(data: data, encoding: .utf8) {
                print(s)
            }
            return 0
        }
    }

    static func cmdGet(_ args: [String]) -> Int32 {
        guard let file = args.first(where: { !$0.hasPrefix("--") }) else {
            FileHandle.standardError.write("usage: human-review get FILE.md --id UUID\n".data(using: .utf8)!)
            return 2
        }
        guard let idStr = flagValue(args, "--id"), let id = UUID(uuidString: idStr) else {
            FileHandle.standardError.write("--id UUID required\n".data(using: .utf8)!); return 2
        }
        let url = resolveURL(file)
        return MainActor.assumeIsolated {
            let store = ReviewStore(fileURL: url, streamToStdout: false)
            guard let c = store.comments.first(where: { $0.id == id }) else {
                FileHandle.standardError.write("not found: \(idStr)\n".data(using: .utf8)!); return 1
            }
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? enc.encode(c), let s = String(data: data, encoding: .utf8) {
                print(s)
            }
            return 0
        }
    }

    static func cmdPrune(_ args: [String]) -> Int32 {
        guard let file = args.first(where: { !$0.hasPrefix("--") }) else {
            FileHandle.standardError.write("usage: human-review prune FILE.md\n".data(using: .utf8)!)
            return 2
        }
        let url = resolveURL(file)
        do {
            try EventLog.truncate(for: url)
            FileHandle.standardError.write("pruned \(EventLog.logURL(for: url).path)\n".data(using: .utf8)!)
            return 0
        } catch {
            FileHandle.standardError.write("prune failed: \(error.localizedDescription)\n".data(using: .utf8)!)
            return 1
        }
    }

    // MARK: tail/filter engine

    /// Spawn `tail -F` over the given log paths. For each line, optionally apply
    /// a types-filter and a predicate that, when true, prints the line and exits.
    /// timeout (seconds) → exit 124 if no match.
    static func tailAndFilter(
        logPaths: [String],
        fromStart: Bool,
        typesFilter: Set<String>?,
        stopOn predicate: ((String) -> Bool)?,
        timeout: Double? = nil,
        printOnly: ((String) -> Bool)? = nil
    ) -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
        // -F follows + reopens on rename/truncate. -n 0 = from-now; -n +1 = replay-all.
        var tailArgs: [String] = ["-F"]
        tailArgs += fromStart ? ["-n", "+1"] : ["-n", "0"]
        tailArgs += logPaths
        task.arguments = tailArgs

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle(forWritingAtPath: "/dev/null") ?? FileHandle.standardError

        do { try task.run() }
        catch {
            FileHandle.standardError.write("failed to spawn tail: \(error)\n".data(using: .utf8)!)
            return 1
        }

        let handle = pipe.fileHandleForReading
        let group = DispatchGroup()
        var matched = false
        var leftover = ""
        let exitCode = NSLock()
        var resultCode: Int32 = 0

        // Optional timeout
        var timer: DispatchSourceTimer?
        if let t = timeout {
            let dt = DispatchSource.makeTimerSource(queue: .global())
            dt.schedule(deadline: .now() + t)
            dt.setEventHandler {
                exitCode.lock()
                if !matched { resultCode = 124 }
                exitCode.unlock()
                task.terminate()
            }
            dt.resume()
            timer = dt
        }

        group.enter()
        handle.readabilityHandler = { fh in
            let data = fh.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                group.leave()
                return
            }
            guard let text = String(data: data, encoding: .utf8) else { return }
            leftover += text
            while let nl = leftover.firstIndex(of: "\n") {
                let line = String(leftover[..<nl])
                leftover = String(leftover[leftover.index(after: nl)...])
                if line.isEmpty { continue }

                // Type filter (watch mode)
                if let allowed = typesFilter {
                    if let data = line.data(using: .utf8),
                       let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                       let ev = obj["event"] as? String,
                       !allowed.contains(ev) { continue }
                }

                let shouldPrint = printOnly?(line) ?? true
                let stop = predicate?(line) ?? false
                if stop {
                    if shouldPrint { print(line); fflush(stdout) }
                    exitCode.lock(); matched = true; exitCode.unlock()
                    task.terminate()
                    return
                }
                if shouldPrint && predicate == nil {
                    print(line); fflush(stdout)
                }
            }
        }

        task.waitUntilExit()
        // Drain
        group.wait()
        timer?.cancel()
        exitCode.lock()
        let code = resultCode
        exitCode.unlock()
        return code
    }

    static func typesValue(_ args: [String]) -> String? { flagValue(args, "--types") }

    // MARK: Helpers

    static func flagValue(_ args: [String], _ name: String) -> String? {
        guard let idx = args.firstIndex(of: name), idx + 1 < args.count else { return nil }
        return args[idx + 1]
    }

    static func resolveURL(_ path: String) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL
    }

    static func nearestBlock(in source: String, around target: Int) -> (start: Int, text: String) {
        let lines = source.components(separatedBy: "\n")
        guard !lines.isEmpty else { return (0, "") }
        let t = min(max(0, target), lines.count - 1)
        var start = t
        while start > 0 && !lines[start - 1].trimmingCharacters(in: .whitespaces).isEmpty {
            start -= 1
        }
        while start < lines.count && lines[start].trimmingCharacters(in: .whitespaces).isEmpty {
            start += 1
        }
        var end = start
        while end < lines.count && !lines[end].trimmingCharacters(in: .whitespaces).isEmpty {
            end += 1
        }
        let block = lines[start..<min(end, lines.count)].joined(separator: "\n")
        return (start, block)
    }
}

// MARK: - AppDelegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let session: ReviewSession
    let router = CommandRouter()
    var window: NSWindow?

    init(session: ReviewSession) { self.session = session }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let root = SessionWindow(session: session)
        let hosting = NSHostingController(rootView: root)
        let win = NSWindow(contentViewController: hosting)
        win.title = "human-review"
        win.setContentSize(NSSize(width: 980, height: 760))
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = win
        installMenu()
        installSignalHandlers()
        router.session = session
        router.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { session.emitExit() }

    private var sigTerm: DispatchSourceSignal?
    private var sigInt: DispatchSourceSignal?

    func installSignalHandlers() {
        let onSignal: () -> Void = { [weak self] in
            self?.session.emitExit()
            self?.session.suppressExitEvent = true
            NSApp.terminate(nil)
        }
        signal(SIGTERM, SIG_IGN)
        let st = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        st.setEventHandler(handler: onSignal); st.resume(); sigTerm = st

        signal(SIGINT, SIG_IGN)
        let si = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        si.setEventHandler(handler: onSignal); si.resume(); sigInt = si
    }

    func installMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "About human-review", action: nil, keyEquivalent: ""))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu

        let fileItem = NSMenuItem()
        main.addItem(fileItem)
        let fm = NSMenu(title: "File")
        let nextI = NSMenuItem(title: "Next File", action: #selector(nextAction), keyEquivalent: "]")
        nextI.target = self; fm.addItem(nextI)
        let prevI = NSMenuItem(title: "Previous File", action: #selector(prevAction), keyEquivalent: "[")
        prevI.target = self; fm.addItem(prevI)
        fm.addItem(NSMenuItem.separator())
        let r = NSMenuItem(title: "Reload Source", action: #selector(reloadAction), keyEquivalent: "r")
        r.target = self; fm.addItem(r)
        fileItem.submenu = fm

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let em = NSMenu(title: "Edit")
        em.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        em.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        em.addItem(NSMenuItem.separator())
        em.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        em.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        em.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        em.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = em

        NSApp.mainMenu = main
    }

    @objc func nextAction()   { session.next() }
    @objc func prevAction()   { session.previous() }
    @objc func reloadAction() { session.current.reload() }
}

// MARK: - Entry

@MainActor
func runApp() {
    exit(CLI.main(CommandLine.arguments))
}

MainActor.assumeIsolated {
    runApp()
}
