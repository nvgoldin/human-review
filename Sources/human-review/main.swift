import AppKit
import SwiftUI
import WebKit
import CryptoKit
import UniformTypeIdentifiers
import Darwin
import Combine

// Line-buffer stdout so JSONL stream events appear immediately even when piped.
setlinebuf(stdout)

// MARK: - Model

/// A single comment. Threads are formed by `replyTo` pointers — a root is a
/// comment with `replyTo == nil`. Only the root carries authoritative
/// `anchorLine` / `anchorText` / `resolved` / `orphaned` values; replies
/// inherit at render time.
/// A comment's anchor scope.
/// - block: anchored to a specific markdown block at `anchorLine`. (default)
/// - global: file-level (no block anchor). Renders in the right-side chat sidebar.
enum CommentScope: String, Codable {
    case block
    case global
}

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
    /// Authors who have explicitly read/ack'd this comment. The comment's own
    /// `author` is implicit and never included here (you don't ack yourself).
    var readBy: [String] = []
    /// Where this comment lives: block-anchored or document-wide. Replies
    /// inherit the scope of their thread root.
    var scope: CommentScope = .block

    enum CodingKeys: String, CodingKey {
        case id, replyTo, anchorLine, anchorText, body, author, createdAt, resolved, orphaned, readBy, scope
    }
    init(id: UUID = UUID(), replyTo: UUID? = nil, anchorLine: Int, anchorText: String,
         body: String, author: String, createdAt: Date = Date(),
         resolved: Bool = false, orphaned: Bool = false, readBy: [String] = [],
         scope: CommentScope = .block) {
        self.id = id; self.replyTo = replyTo
        self.anchorLine = anchorLine; self.anchorText = anchorText
        self.body = body; self.author = author; self.createdAt = createdAt
        self.resolved = resolved; self.orphaned = orphaned; self.readBy = readBy
        self.scope = scope
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.replyTo = try c.decodeIfPresent(UUID.self, forKey: .replyTo)
        self.anchorLine = try c.decode(Int.self, forKey: .anchorLine)
        self.anchorText = try c.decode(String.self, forKey: .anchorText)
        self.body = try c.decode(String.self, forKey: .body)
        self.author = try c.decode(String.self, forKey: .author)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.resolved = try c.decodeIfPresent(Bool.self, forKey: .resolved) ?? false
        self.orphaned = try c.decodeIfPresent(Bool.self, forKey: .orphaned) ?? false
        self.readBy = try c.decodeIfPresent([String].self, forKey: .readBy) ?? []
        self.scope = try c.decodeIfPresent(CommentScope.self, forKey: .scope) ?? .block
    }
}

struct CommentFile: Codable {
    var file: String
    var sourceHash: String
    var comments: [Comment]
    /// Set by `human-review attention …` to ask the GUI to focus on a specific
    /// comment. GUI clears it after acting so it doesn't keep re-focusing.
    var pendingAttention: String? = nil

    enum CodingKeys: String, CodingKey {
        case file, sourceHash, comments, pendingAttention
    }
    init(file: String, sourceHash: String, comments: [Comment], pendingAttention: String? = nil) {
        self.file = file; self.sourceHash = sourceHash
        self.comments = comments; self.pendingAttention = pendingAttention
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.file = try c.decode(String.self, forKey: .file)
        self.sourceHash = try c.decode(String.self, forKey: .sourceHash)
        self.comments = try c.decode([Comment].self, forKey: .comments)
        self.pendingAttention = try c.decodeIfPresent(String.self, forKey: .pendingAttention)
    }
}

struct ViewerPayload: Codable {
    let source: String
    let comments: [Comment]
    let pendingAttention: String?
    /// Current WKWebView pageZoom multiplier (1.0 = native). The JS uses this
    /// to render the floating zoom indicator (e.g. "120%"). Swift owns the
    /// authoritative value; JS sends zoomIn/zoomOut/zoomReset messages.
    let pageZoom: Double
    /// Lowercase file extension with no leading dot (`md`, `py`, `txt`, `js`, …).
    /// Empty for files with no extension. JS uses this to branch between the
    /// markdown renderer (marked.js + mermaid) and per-line syntax-highlighted
    /// code rendering (highlight.js).
    let fileExt: String
    /// Directory holding the source file. The page resolves relative image
    /// paths against it — `document.baseURI` points at the resource bundle,
    /// not at the document.
    let fileDir: String
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
    // .sortedKeys → canonical alphabetical key order. JSON spec doesn't care,
    // but it lets simple regex consumers / line-grep tools rely on a stable
    // shape across event types.
    enc.outputFormatting = [.sortedKeys]
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
        enc.outputFormatting = [.sortedKeys]
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
        guard var data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return }
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
    /// Comment id the GUI should focus next, set by `attention`. Persisted in
    /// the sidecar so it survives across processes / GUI restarts.
    @Published var pendingAttention: UUID? = nil

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
            pendingAttention = loaded.pendingAttention.flatMap { UUID(uuidString: $0) }
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
                pendingAttention = loaded.pendingAttention.flatMap { UUID(uuidString: $0) }
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
            comments: comments,
            pendingAttention: pendingAttention?.uuidString
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
        let lastValidLine = lines.count - 1

        // Bucket block-scoped, non-orphan comments whose anchor still falls
        // inside the current source. Anything else (globals, orphans, stale
        // anchors past EOF after an external truncation) gets rendered in the
        // separate "Document discussion" section at the bottom.
        var byAnchor: [Int: [Comment]] = [:]
        var nonInline: [Comment] = []
        for c in comments {
            if c.scope == .global || c.orphaned || c.anchorLine < 0 || c.anchorLine > lastValidLine {
                nonInline.append(c)
            } else {
                byAnchor[c.anchorLine, default: []].append(c)
            }
        }

        var insertions: [(afterLine: Int, text: String)] = []
        let df = ISO8601DateFormatter()
        df.formatOptions = [.withFullDate]

        for (start, cs) in byAnchor {
            // Find end-of-block. `start` is guaranteed to be in [0, lastValidLine]
            // by the bucketing above; the range can't trap.
            var end = start
            var inFence = false
            for i in start...lastValidLine {
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

        // Append a "Document discussion" section for global threads, orphans,
        // and any comments whose anchorLine no longer maps into the source.
        // Renders below the main body so reading flow stays clean.
        let nonInlineRoots = nonInline.filter { $0.replyTo == nil }
        if !nonInlineRoots.isEmpty {
            out.append("")
            out.append("---")
            out.append("")
            out.append("## Document discussion")
            out.append("")
            for root in nonInlineRoots.sorted(by: { $0.createdAt < $1.createdAt }) {
                let allInThread = thread(rootedAt: root.id)
                let resolvedMark = root.resolved ? " · ✓ resolved" : ""
                let scopeMark: String
                switch (root.scope, root.orphaned) {
                case (.global, _):    scopeMark = " · whole-doc"
                case (.block, true):  scopeMark = " · orphaned (anchor lost)"
                case (.block, false): scopeMark = " · stale anchor"
                }
                out.append("> [!review]\(resolvedMark)\(scopeMark)")
                for (i, c) in allInThread.enumerated() {
                    let when = df.string(from: c.createdAt)
                    let prefix = i == 0 ? "" : "→ "
                    let bodyLines = c.body
                        .components(separatedBy: "\n")
                        .map { "> \($0)" }
                        .joined(separator: "\n")
                    out.append("> \(prefix)**\(c.author)** · \(when)")
                    out.append(bodyLines)
                    if i < allInThread.count - 1 { out.append(">") }
                }
                out.append("")
            }
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
                    replyTo: UUID? = nil, author: String? = nil,
                    scope: CommentScope = .block) -> Comment? {
        let who = author ?? self.author
        var c: Comment
        if let parentId = replyTo {
            guard let rootId = rootId(of: parentId),
                  let root = comments.first(where: { $0.id == rootId }) else {
                statusMessage = "Reply target not found: \(parentId)"
                return nil
            }
            // Replies inherit the root's scope and anchor metadata.
            c = Comment(replyTo: parentId, anchorLine: root.anchorLine,
                        anchorText: root.anchorText, body: body,
                        author: who, resolved: false, orphaned: root.orphaned,
                        scope: root.scope)
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
            // Global comments don't anchor to a specific block — clear the
            // anchor metadata so downstream renderers/exports don't accidentally
            // try to place them inline.
            let resolvedAnchorLine = (scope == .global) ? 0 : line
            let resolvedAnchorText = (scope == .global) ? "" : String(anchorText.prefix(80))
            c = Comment(replyTo: nil, anchorLine: resolvedAnchorLine,
                        anchorText: resolvedAnchorText, body: body,
                        author: who, scope: scope)
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

    /// Mark a comment as read by `reader`. No-op if reader is the comment's own
    /// author, or already in readBy. Emits a `read` event on success.
    /// Mark `id` as the comment the GUI should focus next. Persisted in the
    /// sidecar so it survives across processes. GUI clears via clearAttention()
    /// after acting so subsequent renders don't keep refocusing.
    func setAttention(_ id: UUID) {
        pendingAttention = id
        saveSidecar()
        emit(event: "attention", comment: comments.first(where: { $0.id == id }))
    }

    func clearAttention() {
        if pendingAttention == nil { return }
        pendingAttention = nil
        saveSidecar()
    }

    @discardableResult
    func ackComment(_ id: UUID, by reader: String) -> Bool {
        guard let idx = comments.firstIndex(where: { $0.id == id }) else { return false }
        guard comments[idx].author != reader else { return false }
        guard !comments[idx].readBy.contains(reader) else { return false }
        comments[idx].readBy.append(reader)
        persist()
        emit(event: "read", comment: comments[idx])
        return true
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
    /// WKWebView pageZoom multiplier — persists across file navigation so a
    /// resized session stays sized. 1.0 = native, range clamped to [0.5, 3.0].
    @Published var pageZoom: CGFloat = 1.0
    let stream: Bool
    let emitOnExit: Bool
    var suppressExitEvent: Bool = false
    private var stores: [URL: ReviewStore] = [:]
    private var storeSubs: Set<AnyCancellable> = []
    /// The human's display name — comments authored by anyone else, scoped
    /// global, count as "unread" for them until they navigate to the file.
    let humanName: String

    init(urls: [URL], stream: Bool, emitOnExit: Bool) {
        self.urls = urls
        self.stream = stream
        self.emitOnExit = emitOnExit
        let full = NSFullUserName()
        self.humanName = full.isEmpty ? NSUserName() : full
        for url in urls {
            let store = ReviewStore(fileURL: url, streamToStdout: stream)
            stores[url] = store
            // Re-emit our own changed signal when any store's state changes,
            // so SwiftUI views observing the session (e.g. HeaderBar's badges)
            // refresh when an out-of-focus file gains a new global comment.
            store.objectWillChange
                .sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &storeSubs)
        }
        if stream { emitSessionStart() }
        // Auto-ack globals for the initially-visible file so it doesn't show
        // a stale unread count to the user who is literally about to see them.
        autoAckCurrentGlobals()
    }

    func store(at index: Int) -> ReviewStore { stores[urls[index]]! }
    func store(for url: URL) -> ReviewStore? { stores[url] }
    var current: ReviewStore { stores[urls[currentIndex]]! }
    var totalFiles: Int { urls.count }
    var canGoNext: Bool { currentIndex < urls.count - 1 }
    var canGoPrev: Bool { currentIndex > 0 }

    func next() {
        if canGoNext {
            currentIndex += 1
            autoAckCurrentGlobals()
        }
    }
    func previous() {
        if canGoPrev {
            currentIndex -= 1
            autoAckCurrentGlobals()
        }
    }

    @discardableResult
    func openFile(_ url: URL) -> Int {
        if let i = urls.firstIndex(of: url) { return i }
        urls.append(url)
        let store = ReviewStore(fileURL: url, streamToStdout: stream)
        stores[url] = store
        store.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &storeSubs)
        let perFile = StreamEvent(
            event: "gui_opened", timestamp: Date(), file: url.path,
            comment: nil,
            files: [FileSummary(file: url.path, comments: store.comments)],
            reanchor: nil
        )
        EventLog.append(perFile, for: url)
        return urls.count - 1
    }

    func focusFile(_ url: URL) -> Bool {
        guard let i = urls.firstIndex(of: url) else { return false }
        currentIndex = i
        autoAckCurrentGlobals()
        return true
    }

    func zoomIn()    { pageZoom = min(3.0, (pageZoom * 10).rounded() / 10 + 0.1) }
    func zoomOut()   { pageZoom = max(0.5, (pageZoom * 10).rounded() / 10 - 0.1) }
    func zoomReset() { pageZoom = 1.0 }

    /// Count of unread (by `humanName`) global comments in the file at
    /// `index`. Used by HeaderBar to draw the chevron badge.
    func unreadGlobalsCount(at index: Int) -> Int {
        guard index >= 0, index < urls.count else { return 0 }
        guard let store = stores[urls[index]] else { return 0 }
        var n = 0
        for c in store.comments
        where c.scope == .global
           && c.author != humanName
           && !c.readBy.contains(humanName) {
            n += 1
        }
        return n
    }

    /// Auto-ack every global comment in the currently-focused file under the
    /// human's name. Called on launch and on every navigation.
    private func autoAckCurrentGlobals() {
        guard currentIndex >= 0, currentIndex < urls.count else { return }
        guard let store = stores[urls[currentIndex]] else { return }
        for c in store.comments
        where c.scope == .global
           && c.author != humanName
           && !c.readBy.contains(humanName) {
            store.ackComment(c.id, by: humanName)
        }
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
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
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
                let isGlobal = (obj["global"] as? Bool) ?? false
                if replyTo != nil {
                    // Replies inherit scope from root.
                    store.addComment(line: 0, anchorText: "", body: body,
                                     replyTo: replyTo, author: author)
                } else if isGlobal {
                    store.addComment(line: 0, anchorText: "", body: body,
                                     replyTo: nil, author: author, scope: .global)
                } else {
                    guard let line = obj["line"] as? Int else { throw CmdErr.missing("line") }
                    let (start, text) = CLI.nearestBlock(in: store.source, around: max(0, line - 1))
                    store.addComment(line: start, anchorText: text, body: body,
                                     replyTo: nil, author: author, scope: .block)
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
            case "ack":
                let store = try resolveStore(session, obj)
                guard let idStr = obj["id"] as? String,
                      let id = UUID(uuidString: idStr) else { throw CmdErr.missing("id") }
                let by = (obj["author"] as? String) ?? "agent"
                store.ackComment(id, by: by)
            case "attention":
                let store = try resolveStore(session, obj)
                guard let idStr = obj["id"] as? String,
                      let id = UUID(uuidString: idStr) else { throw CmdErr.missing("id") }
                if store.comments.contains(where: { $0.id == id }) {
                    store.setAttention(id)
                } else {
                    throw CmdErr.unknown("comment not found: \(idStr)")
                }
            case "clearAttention":
                let store = try resolveStore(session, obj)
                store.clearAttention()
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

final class WebViewCoordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    weak var store: ReviewStore?
    weak var session: ReviewSession?
    var onReady: (() -> Void)?

    /// Hands a clicked link to the user's default browser instead of
    /// navigating the review window onto it.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url
        switch LinkPolicy.decide(url: url, currentURL: webView.url,
                                 navigationType: navigationAction.navigationType) {
        case .allowInApp:
            decisionHandler(.allow)
        case .openExternally:
            decisionHandler(.cancel)
            if let url = url { NSWorkspace.shared.open(url) }
        }
    }

    /// `target="_blank"` asks WebKit for a second window. Without this the link
    /// silently does nothing; with it, it opens where the user expects.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { NSWorkspace.shared.open(url) }
        return nil
    }

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
        case "nextFile":
            Task { @MainActor in self.session?.next() }
        case "prevFile":
            Task { @MainActor in self.session?.previous() }
        case "zoomIn", "zoomOut", "zoomReset":
            // SessionWindow's @ObservedObject re-renders SessionWindow but
            // doesn't necessarily re-run MarkdownWebView.updateNSView for a
            // reference-type session whose pageZoom changed in place. Apply
            // the change directly to the webView here, then update the
            // session model so SwiftUI's state stays in sync and other
            // observers (zoom % indicator pushed via applyState, future
            // file-switch initial zoom) see the new value.
            let webView = message.webView
            Task { @MainActor in
                guard let session = self.session else { return }
                switch type {
                case "zoomIn":    session.zoomIn()
                case "zoomOut":   session.zoomOut()
                case "zoomReset": session.zoomReset()
                default: break
                }
                if let webView = webView, webView.pageZoom != session.pageZoom {
                    webView.pageZoom = session.pageZoom
                }
                // Push the new pageZoom to JS so the floating widget updates.
                if let webView = webView, let store = self.store {
                    MarkdownWebView.pushState(webView: webView, store: store, pageZoom: session.pageZoom)
                }
            }
        case "clearAttention":
            Task { @MainActor in self.store?.clearAttention() }
        case "addGlobal":
            guard let body = dict["body"] as? String, !body.isEmpty else { return }
            Task { @MainActor in
                self.store?.addComment(line: 0, anchorText: "", body: body,
                                       replyTo: nil, author: nil, scope: .global)
            }
        case "fetchSection":
            guard let path = dict["path"] as? String else { return }
            CrossLinkOverlay.deliver(path: path,
                                     fragment: (dict["fragment"] as? String) ?? "",
                                     to: message.webView)
        case "openInSession":
            guard let path = dict["path"] as? String else { return }
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
            Task { @MainActor in
                guard let session = self.session else { return }
                if FileManager.default.fileExists(atPath: url.path) {
                    session.openFile(url)
                    _ = session.focusFile(url)
                }
            }
        default:
            break
        }
    }
}

/// Resource bundle lookup that works in both dev (`./install.sh` produces a
/// raw `.build/release/` layout) and prod (`~/Applications/human-review.app/`).
///
/// SwiftPM's generated `Bundle.module` accessor expects the resource
/// `.bundle` to sit at `Bundle.main.bundleURL/<name>.bundle`. For an `.app`,
/// that path resolves to the `.app` root — but Gatekeeper / `codesign`
/// reject "unsealed contents present in the bundle root" if anything sits
/// next to `Contents/`. So we place the resource bundle inside
/// `Contents/Resources/` (the conventional spot) and prefer that location
/// when looking up resources at runtime. We fall back to `Bundle.module`
/// for unbundled dev runs.
enum AppResources {
    static let bundle: Bundle = {
        let name = "human-review_human-review.bundle"
        let candidate = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/\(name)")
        if let b = Bundle(url: candidate) { return b }
        return Bundle.module
    }()
}

/// Reads a cross-linked local file and hands it to the page, which slices out
/// the requested section and shows it in the preview overlay. Shared by the
/// GUI's message handler and by `human-review render --overlay`.
enum CrossLinkOverlay {
    static func deliver(path: String, fragment: String, to webView: WKWebView?) {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        DispatchQueue.global(qos: .userInitiated).async {
            let payload: [String: Any]
            let call: String
            do {
                payload = ["path": url.path, "fragment": fragment,
                           "source": try String(contentsOf: url, encoding: .utf8)]
                call = "showOverlay"
            } catch {
                payload = ["path": url.path, "fragment": fragment,
                           "reason": error.localizedDescription]
                call = "showOverlayError"
            }
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  let json = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                webView?.evaluateJavaScript("if (window.hr && window.hr.\(call)) { window.hr.\(call)(\(json)); }")
            }
        }
    }
}

/// Where a navigation should happen. The review window must never navigate
/// away from `viewer.html` — a clicked link that replaced the UI with a website
/// would lose the session.
enum LinkPolicy {
    enum Decision {
        case allowInApp
        case openExternally
    }

    /// Schemes that always belong to the user's own applications, even when the
    /// page tries to navigate itself there rather than the user clicking.
    private static let externalSchemes: Set<String> = ["http", "https", "mailto", "tel", "ftp", "sms", "facetime"]

    static func decide(url: URL?, currentURL: URL?, navigationType: WKNavigationType) -> Decision {
        guard let url = url else { return .allowInApp }
        if pointsAtSameDocument(url, as: currentURL) { return .allowInApp }
        if navigationType == .linkActivated { return .openExternally }
        let scheme = (url.scheme ?? "").lowercased()
        if externalSchemes.contains(scheme) { return .openExternally }
        return .allowInApp
    }

    /// An in-page anchor navigates to the viewer's own URL with a fragment.
    /// Handing that to the browser would open `viewer.html` in a new window.
    private static func pointsAtSameDocument(_ url: URL, as current: URL?) -> Bool {
        guard let current = current else { return false }
        var target = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var here = URLComponents(url: current, resolvingAgainstBaseURL: false)
        target?.fragment = nil
        here?.fragment = nil
        return target?.url == here?.url
    }
}

/// Serves local image files to the viewer over the `hrimg:` scheme.
///
/// The page cannot use `file:` URLs: `loadFileURL(_:allowingReadAccessTo:)`
/// scopes WebKit's read access to the directory holding `viewer.html`, which is
/// inside the app bundle, so every path outside it is refused. A scheme handler
/// reads the bytes in Swift instead, and streams them rather than inlining them
/// in the payload that gets re-pushed on every mutation.
final class ImageSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "hrimg"

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else {
            task.didFailWithError(URLError(.badURL)); return
        }
        let path = ImageSchemeHandler.canonicalPath(url.path)
        guard let data = FileManager.default.contents(atPath: path) else {
            task.didFailWithError(URLError(.fileDoesNotExist)); return
        }
        let response = URLResponse(url: url, mimeType: ImageSchemeHandler.mimeType(ofPath: path),
                                   expectedContentLength: data.count, textEncodingName: nil)
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    /// Absolute path with `.`, `..`, `~` and symlinks resolved. `/tmp` and
    /// `/var` are symlinks on macOS, so comparing unresolved paths misleads.
    static func canonicalPath(_ path: String) -> String {
        let standardized = (path as NSString).standardizingPath
        return URL(fileURLWithPath: standardized).resolvingSymlinksInPath().path
    }

    static func mimeType(ofPath path: String) -> String {
        let ext = (path as NSString).pathExtension
        if let type = UTType(filenameExtension: ext), let mime = type.preferredMIMEType {
            return mime
        }
        return "application/octet-stream"
    }
}

/// Loads the viewer in an offscreen WKWebView, applies one file's state, then
/// reports what rendered. Used by `human-review render`.
@MainActor
final class HeadlessRenderer: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private let store: ReviewStore
    private let viewerURL: URL
    private let size: CGSize
    private let outPath: String?
    private let settleSeconds: Double
    private let overlayURL: URL?
    private let clickSelector: String?
    private var externalOpens: [String] = []
    private var webView: WKWebView!
    private var window: NSWindow!

    init(store: ReviewStore, viewerURL: URL, size: CGSize, outPath: String?,
         settleSeconds: Double, overlayURL: URL? = nil, clickSelector: String? = nil) {
        self.store = store
        self.viewerURL = viewerURL
        self.size = size
        self.outPath = outPath
        self.settleSeconds = settleSeconds
        self.overlayURL = overlayURL
        self.clickSelector = clickSelector
        super.init()
    }

    func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()
        controller.add(self, name: "swift")
        config.userContentController = controller
        config.setURLSchemeHandler(ImageSchemeHandler(), forURLScheme: ImageSchemeHandler.scheme)
        webView = WKWebView(frame: CGRect(origin: .zero, size: size), configuration: config)
        webView.navigationDelegate = self
        window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = webView
        window.orderBack(nil)
        webView.loadFileURL(viewerURL, allowingReadAccessTo: viewerURL.deletingLastPathComponent())
        DispatchQueue.main.asyncAfter(deadline: .now() + settleSeconds + 20) {
            FileHandle.standardError.write("render timed out\n".data(using: .utf8)!)
            exit(1)
        }
        app.run()
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url
        switch LinkPolicy.decide(url: url, currentURL: webView.url,
                                 navigationType: navigationAction.navigationType) {
        case .allowInApp:
            decisionHandler(.allow)
        case .openExternally:
            decisionHandler(.cancel)
            recordExternalOpen(url?.absoluteString ?? "")
        }
    }

    private func recordExternalOpen(_ url: String) {
        externalOpens.append(url)
    }

    /// Only the messages that change what renders. Everything else the page
    /// sends is a GUI-session concern with no meaning here.
    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let dict = message.body as? [String: Any],
              dict["type"] as? String == "fetchSection",
              let path = dict["path"] as? String else { return }
        CrossLinkOverlay.deliver(path: path, fragment: (dict["fragment"] as? String) ?? "",
                                 to: message.webView)
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                             withError error: Error) {
        FileHandle.standardError.write("viewer failed to load: \(error.localizedDescription)\n".data(using: .utf8)!)
        exit(1)
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in self.applyStateThenReport() }
    }

    private func applyStateThenReport() {
        MarkdownWebView.pushState(webView: webView, store: store)
        openOverlayIfRequested()
        DispatchQueue.main.asyncAfter(deadline: .now() + settleSeconds) {
            Task { @MainActor in self.clickIfRequestedThenReport() }
        }
    }

    private func clickIfRequestedThenReport() {
        guard let selector = clickSelector else { report(); return }
        guard let data = try? JSONSerialization.data(withJSONObject: [selector]),
              let quoted = String(data: data, encoding: .utf8)?.dropFirst().dropLast() else {
            report(); return
        }
        let js = "var el = document.querySelector(\(quoted)); if (el) { el.click(); } !!el"
        webView.evaluateJavaScript(js) { matched, _ in
            if (matched as? Bool) != true {
                FileHandle.standardError.write("no element matched \(selector)\n".data(using: .utf8)!)
                exit(1)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                Task { @MainActor in self.report() }
            }
        }
    }

    /// Opens the cross-link preview on a linked file, the way clicking a
    /// markdown link to another local file does. Images inside it resolve
    /// against that file's directory, not the reviewed one.
    private func openOverlayIfRequested() {
        guard let overlayURL = overlayURL else { return }
        guard let source = try? String(contentsOf: overlayURL, encoding: .utf8) else {
            FileHandle.standardError.write("cannot read overlay file: \(overlayURL.path)\n".data(using: .utf8)!)
            exit(1)
        }
        let payload: [String: Any] = ["path": overlayURL.path, "fragment": "", "source": source]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.hr.showOverlay(\(json)); 'ok'", completionHandler: nil)
    }

    private func report() {
        let js = """
        JSON.stringify({
          blocks: document.querySelectorAll('.block').length,
          images: Array.from(document.querySelectorAll('img')).map(function (i) {
            return { src: i.getAttribute('src') || '', width: i.naturalWidth,
                     loaded: i.complete && i.naturalWidth > 0,
                     attributes: Array.from(i.attributes).map(function (a) { return a.name; }).sort() };
          }),
          overlayVisible: !!document.querySelector('#overlay.visible'),
          notes: Array.from(document.querySelectorAll('.img-note')).map(function (n) {
            return { kind: n.classList.contains('blocked') ? 'blocked' : 'missing',
                     text: n.textContent.trim() };
          })
        })
        """
        let opened = externalOpens
        webView.evaluateJavaScript(js) { value, error in
            if let error = error {
                FileHandle.standardError.write("render probe failed: \(error.localizedDescription)\n".data(using: .utf8)!)
                exit(1)
            }
            print(Self.merge(reportJSON: (value as? String) ?? "{}", externalOpens: opened))
            fflush(stdout)
            Task { @MainActor in self.writeSnapshotAndExit() }
        }
    }

    /// Folds the externally-opened URLs into the page report so the whole
    /// result is one JSON object on stdout.
    static func merge(reportJSON: String, externalOpens: [String]) -> String {
        guard let data = reportJSON.data(using: .utf8),
              var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return reportJSON
        }
        object["externalOpens"] = externalOpens
        guard let merged = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: merged, encoding: .utf8) else { return reportJSON }
        return text
    }

    private func writeSnapshotAndExit() {
        guard let outPath = outPath else { exit(0) }
        let config = WKSnapshotConfiguration()
        config.rect = CGRect(origin: .zero, size: size)
        webView.takeSnapshot(with: config) { image, error in
            guard let image = image, let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else {
                FileHandle.standardError.write("snapshot failed: \(error?.localizedDescription ?? "no image")\n".data(using: .utf8)!)
                exit(1)
            }
            do { try png.write(to: URL(fileURLWithPath: outPath)) }
            catch {
                FileHandle.standardError.write("cannot write \(outPath): \(error.localizedDescription)\n".data(using: .utf8)!)
                exit(1)
            }
            exit(0)
        }
    }
}

struct MarkdownWebView: NSViewRepresentable {
    @ObservedObject var store: ReviewStore
    var session: ReviewSession?

    func makeCoordinator() -> WebViewCoordinator {
        let c = WebViewCoordinator()
        c.store = store
        c.session = session
        return c
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "swift")
        config.userContentController = controller
        config.setURLSchemeHandler(ImageSchemeHandler(), forURLScheme: ImageSchemeHandler.scheme)
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsMagnification = true                  // pinch-to-zoom on trackpads
        // Safari Web Inspector → Develop ▸ <your machine> ▸ human-review.
        // Requires Safari ▸ Settings ▸ Advanced ▸ "Show Develop menu in menu bar".
        // The Package.swift platform floor is macOS 13.0; isInspectable
        // shipped in 13.3, so we have to guard.
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }
        if let s = session { webView.pageZoom = s.pageZoom }

        if let url = AppResources.bundle.url(forResource: "viewer", withExtension: "html") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.loadHTMLString("<h1>viewer.html missing</h1>", baseURL: nil)
        }

        let initialZoom = session?.pageZoom ?? 1.0
        context.coordinator.onReady = { [weak webView] in
            guard let webView = webView else { return }
            Self.pushState(webView: webView, store: store, pageZoom: initialZoom)
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.store = store
        context.coordinator.session = session
        if let s = session, webView.pageZoom != s.pageZoom { webView.pageZoom = s.pageZoom }
        Self.pushState(webView: webView, store: store, pageZoom: session?.pageZoom ?? webView.pageZoom)
    }

    static func pushState(webView: WKWebView, store: ReviewStore, pageZoom: CGFloat = 1.0) {
        let payload = ViewerPayload(
            source: store.source,
            comments: store.comments,
            pendingAttention: store.pendingAttention?.uuidString,
            pageZoom: Double(pageZoom),
            fileExt: store.fileURL.pathExtension.lowercased(),
            fileDir: store.fileURL.deletingLastPathComponent().path
        )
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
    var session: ReviewSession?

    var body: some View {
        VStack(spacing: 0) {
            MarkdownWebView(store: store, session: session)
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

/// Small red rounded badge with a number (caps at "9+"). For chevron unreads.
struct UnreadBadge: View {
    let count: Int
    var body: some View {
        if count > 0 {
            Text(count > 9 ? "9+" : "\(count)")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .frame(minWidth: 16, minHeight: 16)
                .padding(.horizontal, count > 9 ? 3 : 0)
                .background(Capsule().fill(Color.red))
                .offset(x: 8, y: -6)
        }
    }
}

struct HeaderBar: View {
    @ObservedObject var session: ReviewSession

    private var activeCount: Int { session.current.activeThreadRoots.count }
    private var prevUnread: Int { session.unreadGlobalsCount(at: session.currentIndex - 1) }
    private var nextUnread: Int { session.unreadGlobalsCount(at: session.currentIndex + 1) }

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
            Button(action: { session.previous() }) {
                Image(systemName: "chevron.left")
                    .overlay(alignment: .topTrailing) { UnreadBadge(count: prevUnread) }
            }
            .disabled(!session.canGoPrev)
            .help(prevUnread > 0
                  ? "Previous file (⌘[) — \(prevUnread) unread"
                  : "Previous file (⌘[)")
            if session.canGoNext {
                Button(action: { session.next() }) {
                    Image(systemName: "chevron.right")
                        .overlay(alignment: .topTrailing) { UnreadBadge(count: nextUnread) }
                }
                .help(nextUnread > 0
                      ? "Next file (⌘]) — \(nextUnread) unread"
                      : "Next file (⌘])")
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
            FileReviewView(store: session.current, session: session)
                .id(session.currentIndex)
        }
    }
}

// MARK: - CLI

enum CLI {
    static func main(_ argv: [String]) -> Int32 {
        let args = Array(argv.dropFirst())
        guard !args.isEmpty else { printUsage(); return 2 }

        Preferences.writeBannerToStandardError(args)

        let subcommands: Set<String> = [
            "add", "list", "export", "delete", "resolve", "reopen", "reload",
            "watch", "wait", "threads", "get", "prune", "ack", "attention",
            "render", "config", "prompt", "help", "-h", "--help"
        ]
        if subcommands.contains(args[0]) {
            switch args[0] {
            case "help", "-h", "--help": printUsage(); return 0
            case "config":  return ReviewConfig.runConfigCommand(Array(args.dropFirst()))
            case "prompt":  return Preferences.runPromptCommand(Array(args.dropFirst()))
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
            case "ack":     return cmdAck(Array(args.dropFirst()))
            case "attention": return cmdAttention(Array(args.dropFirst()))
            case "render":  return cmdRender(Array(args.dropFirst()))
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
            case "--no-prompt":         break
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
          human-review add     FILE.md --global    --body "TEXT" [--author NAME]
                                                      ^^^^^^^^
              ENTIRE-DOCUMENT thread — not anchored to any block. Renders in the
              right-side "Document chat" sidebar of the GUI. Use this when the
              comment applies to the whole file (overall direction, tone, plan,
              meta-questions) instead of one paragraph. Replies inherit scope
              from their root, so `--reply-to UUID` works the same way.

          human-review resolve FILE.md --id UUID
          human-review reopen  FILE.md --id UUID
          human-review delete  FILE.md --id UUID
          human-review reload  FILE.md
          human-review export  FILE.md

        Read. `get` and `wait` auto-ack the matched comment (read-receipt under
        --author, default "agent") unless you pass --no-ack. `list` and `watch`
        do NOT auto-ack — pass --ack if you want them to.

          human-review list    FILE.md [--scope block|global|all]   All comments as JSON
          human-review threads FILE.md [--active|--settled]
                                       [--scope block|global|all]   Thread roots + reply counts
          human-review get     FILE.md --id UUID [--no-ack] [--author NAME]
          human-review ack     FILE.md --id UUID [--author NAME]   Explicit read receipt

        Subscribe to live events (tails FILE.md.events.jsonl, blocks):

          human-review watch   FILE.md [FILE2 ...] [--from-start] [--types LIST]
              Defaults: emit every new event from now on. `--from-start` replays.
              `--types added,resolved,...` filters event types.

        Block-and-wait helpers (exit 0 on match, 124 on timeout):

          human-review wait    FILE.md --reply-to UUID  [--from-author NAME]
                                                       [--no-ack] [--author NAME] [--timeout S]
              Blocks until any reply lands in the thread containing UUID. Prints
              the matching event JSON. By default the matched reply is ack'd
              under --author (default "agent") — pass --no-ack to skip.

          human-review wait    FILE.md --resolve UUID  [--no-ack] [--author NAME] [--timeout S]
              Blocks until that thread is marked resolved. Auto-acks the root.

          human-review wait    FILE.md --exit                          [--timeout S]
              Blocks until a GUI session closes for that file. No auto-ack.

        Housekeeping:

          human-review prune   FILE.md                  Truncate events.jsonl
          human-review --help                           This text

        ─── Images ─────────────────────────────────────────────────────────────────────
        Markdown images render. CommonMark inline and reference-style forms both
        work, as does a raw <img> tag:

            ![architecture](diagrams/flow.png)
            ![screenshot](../shots/run.png "hover title")
            ![logo][brand]        …        [brand]: assets/logo.svg

        A relative path resolves against the directory holding the file being
        reviewed, not the working directory. Absolute paths work. `data:` URIs
        render as-is.

        Sizing. CommonMark defines no syntax for image dimensions and neither
        does GFM, so none is invented here. Use a raw <img> tag, which is what
        GitHub and Typora tell you to do:

            <img src="diagrams/flow.png" width="480" alt="the flow">

        The `{width=50%}` and `=100x200` forms seen elsewhere are renderer
        extensions, not standards, and marked implements neither.

        Nothing is fetched over the network. An http/https image is not
        requested at all — it renders as a visible "not fetched" marker showing
        the URL. A path that does not exist renders as an "image not found"
        marker. Neither fails silently.

        Render a file without opening a window, to check it in a script:

          human-review render FILE.md [--out shot.png] [--width N] [--height N]
                                      [--overlay LINKED.md] [--wait S]
              Prints a JSON report — block count, every image with whether it
              loaded and which attributes survived, and every blocked/missing
              marker. With --out, also writes a PNG of the rendered page.
              --overlay opens the cross-link preview on another file, so images
              in a linked document can be checked too.

        ─── Preferences (config) ───────────────────────────────────────────────────────
        Your review preferences travel with every command: each subcommand writes
        them to STDERR first, so an agent reading its own transcript follows them
        without being told to look. Stdout stays machine-parseable.

          ── human-review · your review preferences (config global.prompt) ──
          <your preference text>
          ── follow these when you reply to comments ──

        Two git-style INI files, local wins over global key by key:

          ~/.human-reviewconfig            global (override path: HUMAN_REVIEW_CONFIG)
          .human-review.config             nearest one from the working directory up

            [global]
                prompt = "be terse\\nquote the line you mean"
                promptFile = ~/.claude/human-review-preferences.md
                promptQuiet = false

        Keys:
          global.prompt        Preference text injected into agent transcripts.
          global.promptFile    File holding that text. Wins over global.prompt.
          global.promptQuiet   true → no automatic banner. `prompt` still prints.

        Subcommands:
          human-review config [--global|--local] KEY [VALUE]   Read / write one key
          human-review config [--global|--local] --unset KEY   Remove one key
          human-review config [--global|--local] --list        key=value lines, sorted
          human-review config [--global|--local] --path        Path of that file
          human-review config [--global|--local] --edit        Open it in $VISUAL/$EDITOR/vi
          human-review prompt                                  Print the text on stdout

        Reads default to the merged config; writes default to --global. That last
        part deviates from git on purpose — the prompt is a per-user preference,
        and a stray .human-review.config in a working directory would surprise you.

        Suppress the banner:
          global.promptQuiet = true        Always off for this user
          HUMAN_REVIEW_NO_PROMPT=1         Off for this shell
          --no-prompt                      Off for this command (accepted everywhere)

        `config`, `prompt`, and `--help` never print the banner.

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
          {"cmd":"add","file":"…","line":N,"body":"…"}
          {"cmd":"add","file":"…","global":true,"body":"…"}        ← whole-doc thread
          {"cmd":"add","file":"…","replyTo":"UUID","body":"…"}
          {"cmd":"resolve","file":"…","id":"UUID"} | {"cmd":"reopen",…} | {"cmd":"delete",…}
          {"cmd":"ack","file":"…","id":"UUID","author":"agent"}
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
          read          {file, comment}            comment was read (readBy updated)
          reloaded      {file, reanchor:{unchanged,relocated,orphaned}}

        Comment record:
          {id:"UUID", replyTo:"UUID"|null,
           scope:"block"|"global",         ← anchored vs whole-doc
           anchorLine:N0 (0-indexed; meaningful only when scope=="block"),
           anchorText:"first 80 chars of block",
           body:"… (markdown — rendered in GUI)",
           author:"…", createdAt:"ISO8601", resolved:bool, orphaned:bool,
           readBy:["agent", …]}

        Comment bodies are rendered as Markdown in the GUI (GFM + soft-break newlines),
        so use **bold**, `inline code`, lists, and code fences freely.

        Cross-linking. Standard markdown links to OTHER local files open as an
        overlay (preview), not a navigation. Use absolute paths and optional
        anchor fragments:

            satisfies [FSR § 6.4](/Users/me/docs/fsr.md#section-6-4-pull-functions)

        Clicking that link in the GUI opens a modal showing just the section
        whose heading matches the fragment (auto-slug or substring match).
        The overlay has an "Open in review" button that adds the linked file
        to the running session so you can comment on it too.

        Every other link — http, https, mailto, tel — is handed to your default
        browser or mail client. The review window never navigates away from
        itself, so a stray click cannot cost you the session.

        Reading order on file open. When you switch into a file:
          1. If there are unresolved global threads, the sidebar scrolls them
             into view. Unread globals get auto-ack'd by you (NSFullUserName).
          2. If there are unresolved inline (block-anchored) threads, the
             content area auto-jumps to the first one with a yellow pulse.
          3. The header chevrons (⌘[ / ⌘]) show a small red badge with the
             count of unread global comments in the previous / next file
             (caps at 9+). When you arrive at that file, the badge resets.

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
        let author = flagValue(args, "--author") ?? "agent"
        let isGlobal = args.contains("--global")
        let url = resolveURL(file)
        guard FileManager.default.fileExists(atPath: url.path) else {
            FileHandle.standardError.write("file not found: \(file)\n".data(using: .utf8)!); return 1
        }
        return MainActor.assumeIsolated {
            let store = ReviewStore(fileURL: url, streamToStdout: false)
            let result: Comment?
            if let replyStr = flagValue(args, "--reply-to"), let replyId = UUID(uuidString: replyStr) {
                // Replies inherit the root's scope; `--global` is ignored for replies.
                result = store.addComment(line: 0, anchorText: "", body: body, replyTo: replyId, author: author)
            } else if isGlobal {
                result = store.addComment(line: 0, anchorText: "", body: body,
                                          replyTo: nil, author: author, scope: .global)
            } else {
                guard let lineStr = flagValue(args, "--line"), let line = Int(lineStr) else {
                    FileHandle.standardError.write("--line is required (or --reply-to, or --global)\n".data(using: .utf8)!)
                    return 2
                }
                let (start, text) = nearestBlock(in: store.source, around: max(0, line - 1))
                result = store.addComment(line: start, anchorText: text, body: body,
                                          replyTo: nil, author: author, scope: .block)
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
        let scopeFilter: CommentScope? = parseScopeFlag(args)
        return MainActor.assumeIsolated {
            let store = ReviewStore(fileURL: url, streamToStdout: false)
            let filtered = scopeFilter.map { s in store.comments.filter { $0.scope == s } } ?? store.comments
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? enc.encode(filtered), let s = String(data: data, encoding: .utf8) {
                print(s)
            }
            return 0
        }
    }

    /// Parse `--scope block|global|all` from args. Returns nil for "all" (no filter).
    private static func parseScopeFlag(_ args: [String]) -> CommentScope? {
        switch flagValue(args, "--scope") {
        case "block":  return .block
        case "global": return .global
        default:       return nil   // "all" or unspecified → no filter
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
            FileHandle.standardError.write("usage: human-review watch FILE.md [FILE2.md ...] [--from-start] [--types LIST] [--no-ack] [--author NAME]\n".data(using: .utf8)!)
            return 2
        }
        let fromStart = args.contains("--from-start")
        let typesFilter: Set<String>? = typesValue(args).map { Set($0.split(separator: ",").map(String.init)) }
        // Watcher = reader. Auto-ack every `added` event flowing through this
        // watch under --author (default "agent"). Pass --no-ack to disable.
        let ackOnSee = !args.contains("--no-ack")
        let ackAuthor = flagValue(args, "--author") ?? "agent"

        let urls = files.map { resolveURL($0) }
        let logPaths = urls.map { EventLog.logURL(for: $0).path }
        for p in logPaths where !FileManager.default.fileExists(atPath: p) {
            FileManager.default.createFile(atPath: p, contents: nil)
        }

        let onLine: ((String) -> Void)? = ackOnSee ? { line in
            // Parse the event; ack `added` events whose author != ack_author.
            guard let data = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let event = obj["event"] as? String,
                  event == "added",
                  let filePath = obj["file"] as? String,
                  let c = obj["comment"] as? [String: Any],
                  let idStr = c["id"] as? String,
                  let id = UUID(uuidString: idStr) else { return }
            // Skip our own comments — we authored them, not "read" them.
            if (c["author"] as? String) == ackAuthor { return }
            let fileURL = URL(fileURLWithPath: filePath)
            DispatchQueue.main.async {
                let store = ReviewStore(fileURL: fileURL, streamToStdout: false)
                store.ackComment(id, by: ackAuthor)
            }
        } : nil

        return tailAndFilter(logPaths: logPaths, fromStart: fromStart, typesFilter: typesFilter,
                             stopOn: nil, onLine: onLine)
    }

    /// Block until a matching event lands. Mutually-exclusive modes:
    ///   --reply-to UUID      first reply (any author) in that thread
    ///   --resolve   UUID     thread is resolved
    ///   --exit               GUI closes for that file
    /// Prints the full matching event JSON on stdout and exits 0.
    /// On --timeout T (seconds): exits 124 with no output.
    static func cmdWait(_ args: [String]) -> Int32 {
        guard let file = args.first(where: { !$0.hasPrefix("--") }) else {
            FileHandle.standardError.write("usage: human-review wait FILE.md (--reply-to UUID | --resolve UUID | --exit) [--timeout S] [--from-start] [--from-author NAME] [--no-ack] [--author NAME]\n".data(using: .utf8)!)
            return 2
        }
        let replyTo  = flagValue(args, "--reply-to")
        let resolve  = flagValue(args, "--resolve")
        let waitExit = args.contains("--exit")
        let fromAuthor = flagValue(args, "--from-author")
        let timeout = flagValue(args, "--timeout").flatMap { Double($0) }
        let fromStart = args.contains("--from-start")
        let noAck = args.contains("--no-ack")
        let ackAuthor = flagValue(args, "--author") ?? "agent"

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
        let matchedHolder = MatchedLineHolder()

        let predicate: (String) -> Bool = { line in
            guard let data = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let ev = obj["event"] as? String else { return false }

            var matched = false
            if let target = resolve {
                matched = ev == "resolved" && (obj["comment"] as? [String: Any])?["id"] as? String == target
            } else if waitExit {
                matched = ev == "gui_closed"
            } else {
                // reply-to mode
                guard ev == "added", let c = obj["comment"] as? [String: Any] else { return false }
                let parent = c["replyTo"] as? String
                let id = c["id"] as? String
                if let p = parent, threadIds.contains(p), let i = id { threadIds.insert(i) }
                if let p = parent, threadIds.contains(p) {
                    if let want = fromAuthor, (c["author"] as? String) != want {} else { matched = true }
                }
            }
            if matched { matchedHolder.set(line) }
            return matched
        }

        let rc = tailAndFilter(
            logPaths: [logPath], fromStart: fromStart, typesFilter: nil,
            stopOn: predicate, timeout: timeout,
            printOnly: { _ in true }
        )

        // Auto-ack the matched comment unless suppressed. --exit has no specific
        // comment, so we skip ack there.
        if rc == 0, !noAck, !waitExit, let matched = matchedHolder.get(),
           let data = matched.data(using: .utf8),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let c = obj["comment"] as? [String: Any],
           let idStr = c["id"] as? String, let id = UUID(uuidString: idStr) {
            MainActor.assumeIsolated {
                let store = ReviewStore(fileURL: url, streamToStdout: false)
                store.ackComment(id, by: ackAuthor)
            }
        }
        return rc
    }

    final class MatchedLineHolder: @unchecked Sendable {
        private let lock = NSLock()
        private var line: String?
        func set(_ s: String) { lock.lock(); line = s; lock.unlock() }
        func get() -> String? { lock.lock(); defer { lock.unlock() }; return line }
    }

    /// List thread roots for a file. Defaults: all roots. --active / --settled filter.
    static func cmdThreads(_ args: [String]) -> Int32 {
        guard let file = args.first(where: { !$0.hasPrefix("--") }) else {
            FileHandle.standardError.write("usage: human-review threads FILE.md [--active|--settled] [--scope block|global|all]\n".data(using: .utf8)!)
            return 2
        }
        let url = resolveURL(file)
        guard FileManager.default.fileExists(atPath: url.path) else {
            FileHandle.standardError.write("file not found: \(file)\n".data(using: .utf8)!); return 1
        }
        let onlyActive = args.contains("--active")
        let onlySettled = args.contains("--settled")
        let scopeFilter: CommentScope? = parseScopeFlag(args)
        return MainActor.assumeIsolated {
            let store = ReviewStore(fileURL: url, streamToStdout: false)
            var roots = store.threadRoots
            if onlyActive  { roots = roots.filter { !$0.resolved } }
            if onlySettled { roots = roots.filter {  $0.resolved } }
            if let s = scopeFilter { roots = roots.filter { $0.scope == s } }

            // Augment each with replyCount
            let replyCounts: [UUID: Int] = Dictionary(grouping: store.comments.filter { $0.replyTo != nil },
                                                       by: { store.rootId(of: $0.id) ?? $0.id })
                .mapValues { $0.count }

            struct ThreadSummary: Encodable {
                let id: String
                let scope: String
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
                    id: r.id.uuidString, scope: r.scope.rawValue,
                    anchorLine: r.anchorLine, anchorText: r.anchorText,
                    body: r.body, author: r.author,
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

    /// Fetch a single comment. Pulling implies reading: by default this also
    /// acks the comment under --author (default "agent"). Pass --no-ack to fetch
    /// silently. The printed JSON reflects the post-ack state (readBy updated).
    static func cmdGet(_ args: [String]) -> Int32 {
        guard let file = args.first(where: { !$0.hasPrefix("--") }) else {
            FileHandle.standardError.write("usage: human-review get FILE.md --id UUID [--no-ack] [--author NAME]\n".data(using: .utf8)!)
            return 2
        }
        guard let idStr = flagValue(args, "--id"), let id = UUID(uuidString: idStr) else {
            FileHandle.standardError.write("--id UUID required\n".data(using: .utf8)!); return 2
        }
        let url = resolveURL(file)
        let ack = !args.contains("--no-ack")
        let author = flagValue(args, "--author") ?? "agent"
        return MainActor.assumeIsolated {
            let store = ReviewStore(fileURL: url, streamToStdout: false)
            guard store.comments.contains(where: { $0.id == id }) else {
                FileHandle.standardError.write("not found: \(idStr)\n".data(using: .utf8)!); return 1
            }
            if ack { store.ackComment(id, by: author) }
            guard let c = store.comments.first(where: { $0.id == id }) else { return 1 }
            printJSON(c)
            return 0
        }
    }

    /// Ask the GUI to focus on a specific comment (scroll + pulse). Persisted
    /// in the sidecar's pendingAttention field; the GUI clears it after acting.
    static func cmdAttention(_ args: [String]) -> Int32 {
        guard let file = args.first(where: { !$0.hasPrefix("--") }) else {
            FileHandle.standardError.write("usage: human-review attention FILE.md --id UUID\n".data(using: .utf8)!)
            return 2
        }
        guard let idStr = flagValue(args, "--id"), let id = UUID(uuidString: idStr) else {
            FileHandle.standardError.write("--id UUID required\n".data(using: .utf8)!); return 2
        }
        let url = resolveURL(file)
        guard FileManager.default.fileExists(atPath: url.path) else {
            FileHandle.standardError.write("file not found: \(file)\n".data(using: .utf8)!); return 1
        }
        return MainActor.assumeIsolated {
            let store = ReviewStore(fileURL: url, streamToStdout: false)
            guard store.comments.contains(where: { $0.id == id }) else {
                FileHandle.standardError.write("comment not found: \(idStr)\n".data(using: .utf8)!); return 1
            }
            store.setAttention(id)
            printJSON(["file": url.path, "attention": idStr])
            return 0
        }
    }

    /// Explicitly mark a comment as read by --author (default "agent"). No-op
    /// if the reader is the comment's author or already in readBy.
    static func cmdAck(_ args: [String]) -> Int32 {
        guard let file = args.first(where: { !$0.hasPrefix("--") }) else {
            FileHandle.standardError.write("usage: human-review ack FILE.md --id UUID [--author NAME]\n".data(using: .utf8)!)
            return 2
        }
        guard let idStr = flagValue(args, "--id"), let id = UUID(uuidString: idStr) else {
            FileHandle.standardError.write("--id UUID required\n".data(using: .utf8)!); return 2
        }
        let url = resolveURL(file)
        let author = flagValue(args, "--author") ?? "agent"
        return MainActor.assumeIsolated {
            let store = ReviewStore(fileURL: url, streamToStdout: false)
            guard store.comments.contains(where: { $0.id == id }) else {
                FileHandle.standardError.write("not found: \(idStr)\n".data(using: .utf8)!); return 1
            }
            store.ackComment(id, by: author)
            if let c = store.comments.first(where: { $0.id == id }) {
                printJSON(c)
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

    /// Renders a file exactly as the GUI does, without opening a window, and
    /// reports what the page made of it. Answers "does this document render
    /// correctly" from a script: every image is reported as loaded, blocked or
    /// missing, and `--out` writes a PNG of the result.
    static func cmdRender(_ args: [String]) -> Int32 {
        guard let file = args.first(where: { !$0.hasPrefix("--") }) else {
            FileHandle.standardError.write("usage: human-review render FILE [--out PNG] [--width N] [--height N] [--wait S] [--overlay LINKED.md]\n".data(using: .utf8)!)
            return 2
        }
        let url = resolveURL(file)
        guard FileManager.default.fileExists(atPath: url.path) else {
            FileHandle.standardError.write("file not found: \(file)\n".data(using: .utf8)!); return 1
        }
        guard let viewerURL = AppResources.bundle.url(forResource: "viewer", withExtension: "html") else {
            FileHandle.standardError.write("viewer.html missing from the resource bundle\n".data(using: .utf8)!); return 1
        }
        let outPath = flagValue(args, "--out")
        let width = flagValue(args, "--width").flatMap { Double($0) } ?? 1200
        let height = flagValue(args, "--height").flatMap { Double($0) } ?? 900
        let settle = flagValue(args, "--wait").flatMap { Double($0) } ?? 2.0
        var overlayURL: URL? = nil
        if let overlay = flagValue(args, "--overlay") {
            let candidate = resolveURL(overlay)
            guard FileManager.default.fileExists(atPath: candidate.path) else {
                FileHandle.standardError.write("overlay file not found: \(overlay)\n".data(using: .utf8)!); return 1
            }
            overlayURL = candidate
        }

        return MainActor.assumeIsolated {
            let store = ReviewStore(fileURL: url, streamToStdout: false)
            let renderer = HeadlessRenderer(store: store, viewerURL: viewerURL,
                                            size: CGSize(width: width, height: height),
                                            outPath: outPath, settleSeconds: settle,
                                            overlayURL: overlayURL,
                                            clickSelector: flagValue(args, "--click"))
            renderer.run()
            return 0
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
        printOnly: ((String) -> Bool)? = nil,
        onLine: ((String) -> Void)? = nil
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

        let signalSources = makeSignalSourcesTerminating(task)

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

                let isTailFileHeader = line.hasPrefix("==> ") && line.hasSuffix(" <==")
                if isTailFileHeader { continue }

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
                    onLine?(line)
                    exitCode.lock(); matched = true; exitCode.unlock()
                    task.terminate()
                    return
                }
                if shouldPrint && predicate == nil {
                    print(line); fflush(stdout)
                    onLine?(line)
                }
            }
        }

        task.waitUntilExit()
        // Drain
        group.wait()
        timer?.cancel()
        signalSources.forEach { $0.cancel() }
        exitCode.lock()
        let code = resultCode
        exitCode.unlock()
        return code
    }

    /// Kills the spawned `tail` when this process is asked to stop, so a
    /// cancelled `watch` does not leave a `tail -F` following a deleted file.
    static func makeSignalSourcesTerminating(_ task: Process) -> [DispatchSourceSignal] {
        [SIGTERM, SIGINT, SIGHUP].map { signalNumber in
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
            source.setEventHandler {
                if task.isRunning { task.terminate() }
                exit(128 + signalNumber)
            }
            source.resume()
            return source
        }
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

    // Earlier versions of this file tried to warm up the microphone + speech-
    // recognition TCC prompts on launch by calling AVCaptureDevice.requestAccess
    // and SFSpeechRecognizer.requestAuthorization here. The latter crashes the
    // process on macOS 15+ when the binary is launched via a terminal symlink
    // (Bundle.main resolves to the symlink's parent dir, not the .app, so
    // TCC can't find NSSpeechRecognitionUsageDescription even though it's in
    // Contents/Info.plist). Both warm-ups are unnecessary anyway:
    //
    //   - Fn-Fn dictation runs inside the system Dictation daemon, which
    //     handles its own microphone permissions. The user is prompted when
    //     they first enable dictation in System Settings — not by us.
    //   - Microphone access via our own process isn't required: we never call
    //     getUserMedia or open an audio session ourselves.
    //
    // If we later add a custom in-app dictation UI (SFSpeechRecognizer), we'd
    // need to either guard the call with a Bundle.main path check or relaunch
    // the process via `open` to ensure the .app's Info.plist is authoritative.

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

        // View menu — zoom
        //
        // NSMenuItem(keyEquivalent: "+") defaults to modifierMask = [.command]
        // but on US keyboards "+" requires Shift, so ⌘+ never actually fires
        // the menu item. We must explicitly set [.command, .shift] for "+".
        // We also bind an extra "=" item so ⌘= works without Shift.
        let viewItem = NSMenuItem()
        main.addItem(viewItem)
        let vm = NSMenu(title: "View")
        let zi = NSMenuItem(title: "Zoom In", action: #selector(zoomInAction), keyEquivalent: "+")
        zi.keyEquivalentModifierMask = [.command, .shift]
        zi.target = self; vm.addItem(zi)
        // Hidden alternate so ⌘= (no Shift) also zooms in — common Apple convention.
        let ziAlt = NSMenuItem(title: "Zoom In", action: #selector(zoomInAction), keyEquivalent: "=")
        ziAlt.keyEquivalentModifierMask = [.command]
        ziAlt.isAlternate = true
        ziAlt.isHidden = true
        ziAlt.target = self; vm.addItem(ziAlt)
        let zo = NSMenuItem(title: "Zoom Out", action: #selector(zoomOutAction), keyEquivalent: "-")
        zo.keyEquivalentModifierMask = [.command]
        zo.target = self; vm.addItem(zo)
        let zr = NSMenuItem(title: "Actual Size", action: #selector(zoomResetAction), keyEquivalent: "0")
        zr.keyEquivalentModifierMask = [.command]
        zr.target = self; vm.addItem(zr)
        viewItem.submenu = vm

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
        // No manual "Start Dictation…" menu item: the `startDictation:`
        // selector isn't implemented by WKWebView's internal text inputs, so
        // a menu item would beep the same way. Users get dictation via the
        // system shortcut (Fn-Fn) — that's app-agnostic and works inside the
        // WKWebView once TCC has been seeded (done from primeDictationPermissions).
        editItem.submenu = em

        NSApp.mainMenu = main
    }

    @objc func nextAction()   { session.next() }
    @objc func prevAction()   { session.previous() }
    @objc func reloadAction() { session.current.reload() }
    @objc func zoomInAction()    { session.zoomIn() }
    @objc func zoomOutAction()   { session.zoomOut() }
    @objc func zoomResetAction() { session.zoomReset() }
}

// MARK: - Entry

@MainActor
func runApp() {
    exit(CLI.main(CommandLine.arguments))
}

MainActor.assumeIsolated {
    runApp()
}
