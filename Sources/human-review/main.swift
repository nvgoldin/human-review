import AppKit
import SwiftUI
import WebKit
import CryptoKit
import Darwin

// Line-buffer stdout so JSONL stream events appear immediately even when piped.
setlinebuf(stdout)

// MARK: - Model

enum CommentKind: String, Codable {
    case comment   // human-authored review note
    case flag      // agent-authored "needs review" marker
}

struct Comment: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var anchorLine: Int        // 0-indexed line in source where the anchored block starts
    var anchorText: String     // First ~80 chars of the block, used for reload re-anchoring
    var body: String
    var author: String
    var createdAt: Date = Date()
    var orphaned: Bool = false // true if a reload could not relocate anchorText
    var kind: CommentKind = .comment

    enum CodingKeys: String, CodingKey {
        case id, anchorLine, anchorText, body, author, createdAt, orphaned, kind
    }
    init(id: UUID = UUID(), anchorLine: Int, anchorText: String, body: String,
         author: String, createdAt: Date = Date(), orphaned: Bool = false,
         kind: CommentKind = .comment) {
        self.id = id
        self.anchorLine = anchorLine
        self.anchorText = anchorText
        self.body = body
        self.author = author
        self.createdAt = createdAt
        self.orphaned = orphaned
        self.kind = kind
    }
    // Custom decoder so older sidecars (no `orphaned` / `kind` fields) load cleanly.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.anchorLine = try c.decode(Int.self, forKey: .anchorLine)
        self.anchorText = try c.decode(String.self, forKey: .anchorText)
        self.body = try c.decode(String.self, forKey: .body)
        self.author = try c.decode(String.self, forKey: .author)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.orphaned = try c.decodeIfPresent(Bool.self, forKey: .orphaned) ?? false
        self.kind = try c.decodeIfPresent(CommentKind.self, forKey: .kind) ?? .comment
    }
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
    let unchanged: Int   // anchorText found at same line
    let relocated: Int   // anchorText found at a different line; anchorLine updated
    let orphaned: Int    // anchorText not found anywhere; comment kept but flagged
}

struct StreamEvent: Codable {
    let event: String              // "session_start" | "added" | "deleted" | "edited" | "reloaded" | "exit"
    let timestamp: Date
    let file: String?              // nil for session-level events
    let comment: Comment?
    let files: [FileSummary]?      // session_start / exit
    let reanchor: ReanchorStats?   // reloaded
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
    /// Hash of the source the current `comments[*].anchorLine` values are valid for.
    /// reload() compares this against the disk source's hash to detect drift.
    private var anchoredSourceHash: String = ""

    init(fileURL: URL, streamToStdout: Bool) {
        self.fileURL = fileURL
        self.sidecarURL = fileURL.appendingPathExtension("comments.json")
        let exportName = fileURL.deletingPathExtension().lastPathComponent + ".review.md"
        self.exportURL = fileURL.deletingLastPathComponent().appendingPathComponent(exportName)
        let full = NSFullUserName()
        self.author = full.isEmpty ? NSUserName() : full
        self.streamToStdout = streamToStdout
        load()
    }

    func load() {
        do {
            source = try String(contentsOf: fileURL, encoding: .utf8)
        } catch {
            source = "# Could not read \(fileURL.lastPathComponent)\n\n\(error.localizedDescription)"
        }
        // Default: assume comments are anchored against the disk source unless the
        // sidecar records a different hash (meaning the file drifted since save).
        anchoredSourceHash = source.sha256Prefix()
        if FileManager.default.fileExists(atPath: sidecarURL.path) {
            do {
                let data = try Data(contentsOf: sidecarURL)
                let dec = JSONDecoder()
                dec.dateDecodingStrategy = .iso8601
                let loaded = try dec.decode(CommentFile.self, from: data)
                comments = loaded.comments.sorted { $0.anchorLine < $1.anchorLine }
                anchoredSourceHash = loaded.sourceHash
            } catch {
                statusMessage = "Failed to load sidecar: \(error.localizedDescription)"
            }
        }
    }

    @discardableResult
    func saveSidecar() -> Bool {
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
            try enc.encode(payload).write(to: sidecarURL, options: .atomic)
            anchoredSourceHash = hash  // comments now aligned with this source
            return true
        } catch {
            statusMessage = "Save failed: \(error.localizedDescription)"
            return false
        }
    }

    /// Write inline `<basename>.review.md` with [!review] callouts after each anchored block.
    /// If no comments, deletes any stale .review.md.
    func writeInlineExport() {
        guard !comments.isEmpty else {
            try? FileManager.default.removeItem(at: exportURL)
            return
        }
        let lines = source.components(separatedBy: "\n")
        var byAnchor: [Int: [Comment]] = [:]
        for c in comments { byAnchor[c.anchorLine, default: []].append(c) }

        var insertions: [(afterLine: Int, text: String)] = []
        for (start, cs) in byAnchor {
            var end = start
            var inFence = false
            for i in start..<lines.count {
                let line = lines[i]
                if line.range(of: #"^\s*(```|~~~)"#, options: .regularExpression) != nil {
                    inFence.toggle()
                }
                if !inFence && line.trimmingCharacters(in: .whitespaces).isEmpty {
                    end = i - 1
                    break
                }
                end = i
            }
            let df = ISO8601DateFormatter()
            df.formatOptions = [.withFullDate]
            var block = ""
            for c in cs.sorted(by: { $0.createdAt < $1.createdAt }) {
                let when = df.string(from: c.createdAt)
                let bodyLines = c.body
                    .components(separatedBy: "\n")
                    .map { "> \($0)" }
                    .joined(separator: "\n")
                block += "\n> [!review] \(c.author) · \(when)\n\(bodyLines)\n"
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
        statusMessage = "Saved \(comments.count) comment\(comments.count == 1 ? "" : "s")"
    }

    @discardableResult
    func addComment(line: Int, anchorText: String, body: String,
                    kind: CommentKind = .comment, author: String? = nil) -> Comment {
        let snippet = String(anchorText.prefix(80))
        let who = author ?? self.author
        let c = Comment(anchorLine: line, anchorText: snippet, body: body,
                        author: who, kind: kind)
        comments.append(c)
        comments.sort { $0.anchorLine < $1.anchorLine }
        persist()
        emit(event: kind == .flag ? "flagged" : "added", comment: c)
        return c
    }

    @discardableResult
    func addFlag(line: Int, anchorText: String, reason: String,
                 author: String = "agent") -> Comment {
        return addComment(line: line, anchorText: anchorText, body: reason,
                          kind: .flag, author: author)
    }

    func deleteComment(_ id: UUID) {
        guard let removed = comments.first(where: { $0.id == id }) else { return }
        comments.removeAll { $0.id == id }
        persist()
        // Flag-kind comments are "resolved" rather than "deleted" — semantically the
        // human (or agent) just marked the agent's flag as handled.
        emit(event: removed.kind == .flag ? "resolved" : "deleted", comment: removed)
    }

    func editComment(_ id: UUID, body: String) {
        guard let idx = comments.firstIndex(where: { $0.id == id }) else { return }
        comments[idx].body = body
        persist()
        emit(event: "edited", comment: comments[idx])
    }

    /// Re-read source from disk and try to relocate every comment by searching for
    /// its stored `anchorText`. Returns stats describing what moved.
    @discardableResult
    func reload() -> ReanchorStats {
        do {
            source = try String(contentsOf: fileURL, encoding: .utf8)
        } catch {
            statusMessage = "Reload failed: \(error.localizedDescription)"
            return ReanchorStats(unchanged: 0, relocated: 0, orphaned: 0)
        }

        // Fast path: comments are already anchored against this exact source.
        let diskHash = source.sha256Prefix()
        if diskHash == anchoredSourceHash {
            statusMessage = "Reloaded — source unchanged"
            let stats = ReanchorStats(unchanged: comments.count, relocated: 0, orphaned: 0)
            if streamToStdout {
                emitEvent(StreamEvent(
                    event: "reloaded",
                    timestamp: Date(),
                    file: fileURL.path,
                    comment: nil,
                    files: nil,
                    reanchor: stats
                ))
            }
            return stats
        }

        var unchanged = 0
        var relocated = 0
        var orphans = 0
        let lines = source.components(separatedBy: "\n")

        for i in 0..<comments.count {
            let original = comments[i].anchorLine
            let probe = comments[i].anchorText
                .components(separatedBy: "\n")
                .first?
                .trimmingCharacters(in: .whitespaces) ?? ""
            guard !probe.isEmpty else { orphans += 1; comments[i].orphaned = true; continue }

            // Find every line where the probe appears.
            let hits = lines.enumerated().compactMap { (idx, line) -> Int? in
                line.trimmingCharacters(in: .whitespaces).hasPrefix(probe) ? idx : nil
            }
            guard let best = hits.min(by: { abs($0 - original) < abs($1 - original) }) else {
                comments[i].orphaned = true
                orphans += 1
                continue
            }
            // Walk back to block start (previous blank line / BOF).
            var start = best
            while start > 0 && !lines[start - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                start -= 1
            }
            comments[i].orphaned = false
            if start == original { unchanged += 1 }
            else { comments[i].anchorLine = start; relocated += 1 }
        }
        comments.sort { $0.anchorLine < $1.anchorLine }

        // Persist new anchors + regenerate .review.md against the new source.
        saveSidecar()
        writeInlineExport()

        let stats = ReanchorStats(unchanged: unchanged, relocated: relocated, orphaned: orphans)
        statusMessage = "Reloaded · \(unchanged) unchanged · \(relocated) relocated · \(orphans) orphaned"
        if streamToStdout {
            emitEvent(StreamEvent(
                event: "reloaded",
                timestamp: Date(),
                file: fileURL.path,
                comment: nil,
                files: nil,
                reanchor: stats
            ))
        }
        return stats
    }

    private func emit(event: String, comment: Comment?) {
        guard streamToStdout else { return }
        emitEvent(StreamEvent(
            event: event,
            timestamp: Date(),
            file: fileURL.path,
            comment: comment,
            files: nil,
            reanchor: nil
        ))
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
        if stream {
            emitSessionStart()
        }
    }

    func store(at index: Int) -> ReviewStore { stores[urls[index]]! }
    func store(for url: URL) -> ReviewStore? { stores[url] }
    var current: ReviewStore { stores[urls[currentIndex]]! }
    var totalFiles: Int { urls.count }
    var canGoNext: Bool { currentIndex < urls.count - 1 }
    var canGoPrev: Bool { currentIndex > 0 }

    func next() { if canGoNext { currentIndex += 1 } }
    func previous() { if canGoPrev { currentIndex -= 1 } }

    /// Append a file to the session at runtime. Returns the index of the
    /// (possibly already-present) entry. Idempotent.
    @discardableResult
    func openFile(_ url: URL) -> Int {
        if let i = urls.firstIndex(of: url) { return i }
        urls.append(url)
        stores[url] = ReviewStore(fileURL: url, streamToStdout: stream)
        return urls.count - 1
    }

    func focusFile(_ url: URL) -> Bool {
        guard let i = urls.firstIndex(of: url) else { return false }
        currentIndex = i
        return true
    }

    private func emitSessionStart() {
        emitEvent(StreamEvent(
            event: "session_start",
            timestamp: Date(),
            file: nil,
            comment: nil,
            files: fileSummaries(),
            reanchor: nil
        ))
    }

    func emitExit() {
        guard emitOnExit, !suppressExitEvent else { return }
        suppressExitEvent = true
        emitEvent(StreamEvent(
            event: "exit",
            timestamp: Date(),
            file: nil,
            comment: nil,
            files: fileSummaries(),
            reanchor: nil
        ))
    }

    func emitFileEvent(_ event: String, file: URL) {
        guard stream else { return }
        emitEvent(StreamEvent(
            event: event,
            timestamp: Date(),
            file: file.path,
            comment: nil,
            files: nil,
            reanchor: nil
        ))
    }

    func emitCommandError(_ raw: String, _ reason: String) {
        guard stream else { return }
        let payload: [String: Any] = [
            "event": "command_error",
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "reason": reason,
            "raw": raw
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

/// Background reader that consumes one JSONL command per line from stdin.
/// Active only when stdin is not a tty (i.e., the binary was launched with
/// stdin piped from an agent). Idle when launched interactively.
@MainActor
final class CommandRouter {
    weak var session: ReviewSession?

    func start() {
        // Don't read stdin when it's the controlling terminal — that'd swallow
        // every keystroke the user types into the shell that launched us.
        if isatty(fileno(stdin)) != 0 { return }
        let handle = FileHandle.standardInput
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            // Use readLine on stdin via fgets — straightforward, blocking, EOF-safe.
            while let line = Swift.readLine(strippingNewline: true) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { continue }
                DispatchQueue.main.async {
                    self.handle(trimmed)
                }
            }
            _ = handle  // keep handle reference alive for the lifetime of the loop
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

        switch cmd {
        case "ping":
            session.emitFileEvent("pong", file: URL(fileURLWithPath: ""))
        case "flag":
            do { try requireFile(session, obj) { store, line in
                let reason = (obj["reason"] as? String) ?? (obj["body"] as? String) ?? ""
                guard !reason.isEmpty else { throw CmdErr.missing("reason") }
                let (start, text) = CLI.nearestBlock(in: store.source, around: max(0, line))
                store.addFlag(line: start, anchorText: text, reason: reason)
            }} catch { session.emitCommandError(raw, "\(error)") }
        case "add":
            do { try requireFile(session, obj) { store, line in
                guard let body = obj["body"] as? String, !body.isEmpty else {
                    throw CmdErr.missing("body")
                }
                let who = (obj["author"] as? String) ?? "agent"
                let (start, text) = CLI.nearestBlock(in: store.source, around: max(0, line))
                store.addComment(line: start, anchorText: text, body: body,
                                 kind: .comment, author: who)
            }} catch { session.emitCommandError(raw, "\(error)") }
        case "resolve":
            do {
                let store = try resolveStore(session, obj)
                guard let idStr = obj["id"] as? String, let id = UUID(uuidString: idStr) else {
                    throw CmdErr.missing("id")
                }
                store.deleteComment(id)
            } catch { session.emitCommandError(raw, "\(error)") }
        case "reload":
            do {
                let store = try resolveStore(session, obj)
                store.reload()
            } catch { session.emitCommandError(raw, "\(error)") }
        case "open":
            guard let path = obj["file"] as? String else {
                session.emitCommandError(raw, "missing 'file'"); return
            }
            let url = CLI.resolveURL(path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                session.emitCommandError(raw, "file not found: \(path)"); return
            }
            session.openFile(url)
            session.emitFileEvent("opened", file: url)
        case "focus":
            guard let path = obj["file"] as? String else {
                session.emitCommandError(raw, "missing 'file'"); return
            }
            let url = CLI.resolveURL(path)
            if session.focusFile(url) {
                session.emitFileEvent("focused", file: url)
            } else {
                session.emitCommandError(raw, "file not in session: \(path)")
            }
        default:
            session.emitCommandError(raw, "unknown cmd: \(cmd)")
        }
    }

    enum CmdErr: Error, CustomStringConvertible {
        case missing(String), notInSession(String)
        var description: String {
            switch self {
            case .missing(let f): return "missing '\(f)'"
            case .notInSession(let p): return "file not in session: \(p)"
            }
        }
    }

    private func resolveStore(_ session: ReviewSession, _ obj: [String: Any]) throws -> ReviewStore {
        guard let path = obj["file"] as? String else { throw CmdErr.missing("file") }
        let url = CLI.resolveURL(path)
        guard let store = session.store(for: url) else { throw CmdErr.notInSession(path) }
        return store
    }

    private func requireFile(_ session: ReviewSession,
                             _ obj: [String: Any],
                             body: (ReviewStore, Int) throws -> Void) throws {
        let store = try resolveStore(session, obj)
        guard let line = obj["line"] as? Int else { throw CmdErr.missing("line") }
        // Convert 1-indexed from agent to 0-indexed internally
        try body(store, line - 1)
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
            guard let line = dict["line"] as? Int,
                  let text = dict["text"] as? String,
                  let body = dict["body"] as? String else { return }
            Task { @MainActor in self.store?.addComment(line: line, anchorText: text, body: body) }
        case "deleteComment":
            if let idStr = dict["id"] as? String, let id = UUID(uuidString: idStr) {
                Task { @MainActor in self.store?.deleteComment(id) }
            }
        case "editComment":
            if let idStr = dict["id"] as? String, let id = UUID(uuidString: idStr),
               let body = dict["body"] as? String {
                Task { @MainActor in self.store?.editComment(id, body: body) }
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
            webView.loadHTMLString("<h1>viewer.html missing from bundle</h1>", baseURL: nil)
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
        let js = "if (window.mdReview) { window.mdReview.applyState(\(jsonStr)); }"
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
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Text("\(store.comments.count) comment\(store.comments.count == 1 ? "" : "s")")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
    }
}

struct HeaderBar: View {
    @ObservedObject var session: ReviewSession

    private var flagCount: Int {
        session.current.comments.filter { $0.kind == .flag }.count
    }

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
            if flagCount > 0 {
                Text("🚩 \(flagCount)")
                    .font(.caption.monospaced())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.yellow.opacity(0.25))
                    .cornerRadius(4)
                    .help("\(flagCount) flag\(flagCount == 1 ? "" : "s") — press n / N to navigate")
            }
            Spacer()
            Button(action: { session.previous() }) {
                Image(systemName: "chevron.left")
            }
            .disabled(!session.canGoPrev)
            .help("Previous file (⌘[)")
            if session.canGoNext {
                Button(action: { session.next() }) {
                    Image(systemName: "chevron.right")
                }
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
            // .id forces SwiftUI to rebuild the subtree (incl. fresh WKWebView) when the file changes.
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

        // Subcommand routing (only when first arg is an exact subcommand keyword)
        let subcommands: Set<String> = ["add", "flag", "list", "export", "delete", "resolve", "reload", "help", "-h", "--help"]
        if subcommands.contains(args[0]) {
            switch args[0] {
            case "help", "-h", "--help": printUsage(); return 0
            case "add":     return cmdAdd(Array(args.dropFirst()))
            case "flag":    return cmdFlag(Array(args.dropFirst()))
            case "list":    return cmdList(Array(args.dropFirst()))
            case "export":  return cmdExport(Array(args.dropFirst()))
            case "delete":  return cmdDelete(Array(args.dropFirst()))
            case "resolve": return cmdDelete(Array(args.dropFirst()))   // same code path
            case "reload":  return cmdReload(Array(args.dropFirst()))
            default: break
            }
        }

        // GUI mode. Defaults: stream on, emit-on-exit on. Disable with --no-* flags.
        var stream = true
        var emitOnExit = true
        var filePaths: [String] = []
        for a in args {
            switch a {
            case "--no-stream":         stream = false
            case "--no-emit-on-exit":   emitOnExit = false
            case "--stream":            stream = true        // explicit, kept for compat
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

        GUI mode (default — stream + emit-on-exit are ON):
          human-review file1.md [file2.md ...]    Open review window(s)
          --no-stream            Disable live JSONL events on stdout
          --no-emit-on-exit      Disable final exit-summary event

          In the window: hover a block, click +, write a comment. Auto-saved.
          ⌘]  next file        ⌘[  previous file
          ⌘W  close window     ⌘R  reload current source from disk
          Cmd+Enter submits the active composer, Esc cancels.

        Headless subcommands (no GUI):
          human-review add <file.md> --line N --body "TEXT" [--author NAME]
          human-review flag <file.md> --line N --reason "TEXT" [--author NAME]
          human-review list <file.md>
          human-review delete <file.md> --id UUID    (alias: resolve)
          human-review export <file.md>
          human-review reload <file.md>   Re-anchor comments after editing source

        Live agent control (stdin JSONL — only when stdin is piped):
          {"cmd":"flag","file":"…","line":N,"reason":"…"}
          {"cmd":"add","file":"…","line":N,"body":"…"}
          {"cmd":"resolve","file":"…","id":"UUID"}
          {"cmd":"reload","file":"…"}
          {"cmd":"open","file":"…"}      (append a new file to the running session)
          {"cmd":"focus","file":"…"}     (switch GUI to that file)
          {"cmd":"ping"}                  (round-trip liveness — replies "pong")

        Always-on side effects per file:
          <file>.md.comments.json   sidecar store (canonical state)
          <file>.review.md          inline-annotated markdown (regenerated on every change)

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

    // MARK: - Headless subcommands

    static func cmdAdd(_ args: [String]) -> Int32 {
        guard let file = args.first(where: { !$0.hasPrefix("--") }) else {
            FileHandle.standardError.write("missing <file>\n".data(using: .utf8)!); return 2
        }
        let lineStr = flagValue(args, "--line") ?? ""
        let body = flagValue(args, "--body") ?? ""
        guard let line = Int(lineStr) else {
            FileHandle.standardError.write("--line is required (integer, 1-indexed)\n".data(using: .utf8)!); return 2
        }
        guard !body.isEmpty else {
            FileHandle.standardError.write("--body is required\n".data(using: .utf8)!); return 2
        }
        let url = resolveURL(file)
        guard FileManager.default.fileExists(atPath: url.path) else {
            FileHandle.standardError.write("file not found: \(file)\n".data(using: .utf8)!); return 1
        }
        return MainActor.assumeIsolated {
            let store = ReviewStore(fileURL: url, streamToStdout: true)
            let target = max(0, line - 1)
            let (blockStart, blockText) = nearestBlock(in: store.source, around: target)
            store.addComment(line: blockStart, anchorText: blockText, body: body)
            return 0
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

    static func cmdFlag(_ args: [String]) -> Int32 {
        guard let file = args.first(where: { !$0.hasPrefix("--") }) else {
            FileHandle.standardError.write("missing <file>\n".data(using: .utf8)!); return 2
        }
        let lineStr = flagValue(args, "--line") ?? ""
        let reason = flagValue(args, "--reason") ?? flagValue(args, "--body") ?? ""
        guard let line = Int(lineStr) else {
            FileHandle.standardError.write("--line is required (integer, 1-indexed)\n".data(using: .utf8)!); return 2
        }
        guard !reason.isEmpty else {
            FileHandle.standardError.write("--reason (or --body) is required\n".data(using: .utf8)!); return 2
        }
        let author = flagValue(args, "--author") ?? "agent"
        let url = resolveURL(file)
        guard FileManager.default.fileExists(atPath: url.path) else {
            FileHandle.standardError.write("file not found: \(file)\n".data(using: .utf8)!); return 1
        }
        return MainActor.assumeIsolated {
            let store = ReviewStore(fileURL: url, streamToStdout: true)
            let target = max(0, line - 1)
            let (blockStart, blockText) = nearestBlock(in: store.source, around: target)
            store.addFlag(line: blockStart, anchorText: blockText, reason: reason, author: author)
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
            let store = ReviewStore(fileURL: url, streamToStdout: true)
            store.reload()
            return 0
        }
    }

    static func cmdDelete(_ args: [String]) -> Int32 {
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
            let store = ReviewStore(fileURL: url, streamToStdout: true)
            store.deleteComment(id)
            return 0
        }
    }

    // MARK: - Helpers

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

    init(session: ReviewSession) {
        self.session = session
    }

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

    private var sigTerm: DispatchSourceSignal?
    private var sigInt: DispatchSourceSignal?

    func installSignalHandlers() {
        // Route SIGTERM/SIGINT through Cocoa's normal teardown so applicationWillTerminate fires.
        let onSignal: () -> Void = { [weak self] in
            self?.session.emitExit()
            // Suppress the duplicate from applicationWillTerminate.
            self?.session.suppressExitEvent = true
            NSApp.terminate(nil)
        }
        signal(SIGTERM, SIG_IGN)
        let st = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        st.setEventHandler(handler: onSignal)
        st.resume()
        sigTerm = st

        signal(SIGINT, SIG_IGN)
        let si = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        si.setEventHandler(handler: onSignal)
        si.resume()
        sigInt = si
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        session.emitExit()
    }

    func installMenu() {
        let main = NSMenu()

        // App menu
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "About human-review", action: nil, keyEquivalent: ""))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu

        // File menu — navigation only, no save/export
        let fileItem = NSMenuItem()
        main.addItem(fileItem)
        let fm = NSMenu(title: "File")
        let next = NSMenuItem(title: "Next File", action: #selector(nextAction), keyEquivalent: "]")
        next.target = self; fm.addItem(next)
        let prev = NSMenuItem(title: "Previous File", action: #selector(prevAction), keyEquivalent: "[")
        prev.target = self; fm.addItem(prev)
        fm.addItem(NSMenuItem.separator())
        let r = NSMenuItem(title: "Reload Source", action: #selector(reloadAction), keyEquivalent: "r")
        r.target = self; fm.addItem(r)
        fileItem.submenu = fm

        // Edit menu (so Cmd+C/V/A work in the composer)
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

exit(CLI.main(CommandLine.arguments))
