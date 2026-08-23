import Foundation
import Testing

struct CommandResult {
    let exitCode: Int32
    let standardOutput: String
    let standardError: String
}

/// Isolated working directory, throwaway global config, and a runner that
/// drives the built binary the way a shell does. One fixture per test.
final class ReviewCLIFixture: @unchecked Sendable {

    let workingDirectory: URL
    let globalConfigPath: String

    init(withSourceFile: Bool = false) {
        workingDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("human-review-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        globalConfigPath = workingDirectory.appendingPathComponent("global.human-reviewconfig").path
        if withSourceFile { writeSourceFile() }
    }

    deinit {
        try? FileManager.default.removeItem(at: workingDirectory)
    }

    // MARK: - Running the binary

    @discardableResult
    func run(_ arguments: [String], environment: [String: String] = [:]) -> CommandResult {
        let process = makeProcess(arguments, environment: environment)
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
        } catch {
            Issue.record("cannot run \(Self.binaryPath): \(error)")
            return CommandResult(exitCode: -1, standardOutput: "", standardError: "")
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandResult(
            exitCode: process.terminationStatus,
            standardOutput: String(decoding: outData, as: UTF8.self),
            standardError: String(decoding: errData, as: UTF8.self)
        )
    }

    /// Starts the binary without waiting. The caller drives it with
    /// `collectOutput(of:until:)` and terminates it.
    func startInBackground(_ arguments: [String], environment: [String: String] = [:]) -> (Process, Pipe) {
        let process = makeProcess(arguments, environment: environment)
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            Issue.record("cannot run \(Self.binaryPath): \(error)")
        }
        return (process, outPipe)
    }

    /// Reads the pipe until `predicate` accepts the accumulated text or the
    /// deadline passes. Returns everything read so far.
    func collectOutput(of pipe: Pipe, until predicate: @escaping @Sendable (String) -> Bool,
                       timeout: TimeInterval = 20) -> String {
        let collected = TextAccumulator()
        let satisfied = DispatchSemaphore(value: 0)
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                satisfied.signal()
                return
            }
            collected.append(String(decoding: data, as: UTF8.self))
            if predicate(collected.text) { satisfied.signal() }
        }
        _ = satisfied.wait(timeout: .now() + timeout)
        pipe.fileHandleForReading.readabilityHandler = nil
        return collected.text
    }

    func terminate(_ process: Process) {
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
    }

    private func makeProcess(_ arguments: [String], environment: [String: String]) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.binaryPath)
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        var merged = ProcessInfo.processInfo.environment
        merged["HUMAN_REVIEW_CONFIG"] = globalConfigPath
        merged.removeValue(forKey: "HUMAN_REVIEW_NO_PROMPT")
        for (key, value) in environment { merged[key] = value }
        process.environment = merged
        return process
    }

    // MARK: - Files

    func writeSourceFile(named name: String = "notes.md",
                         contents: String = ReviewCLIFixture.sampleMarkdown) {
        try? contents.write(to: workingDirectory.appendingPathComponent(name),
                            atomically: true, encoding: .utf8)
    }

    func writeGlobalConfig(_ contents: String) {
        try? contents.write(toFile: globalConfigPath, atomically: true, encoding: .utf8)
    }

    func writeTextFile(named name: String, contents: String) {
        try? contents.write(toFile: path(name), atomically: true, encoding: .utf8)
    }

    func path(_ name: String) -> String {
        workingDirectory.appendingPathComponent(name).path
    }

    /// The same path the CLI reports, with every symlink in the working
    /// directory resolved the way `realpath` does.
    func resolvedPath(_ name: String) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(workingDirectory.path, &buffer) != nil else { return path(name) }
        return (String(cString: buffer) as NSString).appendingPathComponent(name)
    }

    func fileExists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: path(name))
    }

    func contentsOfFile(_ name: String) -> String {
        (try? String(contentsOfFile: path(name), encoding: .utf8)) ?? ""
    }

    func eventLogLines(of sourceName: String = "notes.md") -> [String] {
        contentsOfFile("\(sourceName).events.jsonl")
            .components(separatedBy: "\n")
            .filter { !$0.isEmpty }
    }

    static let sampleMarkdown = """
    alpha block
    still alpha

    beta block

    gamma block

    """

    // MARK: - Comments

    @discardableResult
    func addRootComment(to sourceName: String = "notes.md", line: Int = 4,
                        body: String = "root note") -> String {
        let result = run(["add", sourceName, "--line", String(line), "--body", body])
        #expect(result.exitCode == 0, "\(result.standardError)")
        return jsonObject(result.standardOutput)?["id"] as? String ?? ""
    }

    func jsonObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    func jsonArray(_ text: String) -> [[String: Any]]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
    }

    func bannerCount(in text: String) -> Int {
        text.components(separatedBy: "── human-review · your review preferences (config global.prompt) ──").count - 1
    }

    /// Key order of every JSON object in `text`, as the keys appear in the raw
    /// bytes.
    func objectKeyOrders(inJSONText text: String) -> [[String]] {
        enum Container { case object(Int), array }
        var orders: [[String]] = []
        var stack: [Container] = []
        var expectingKey = false
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\"" {
                var cursor = index + 1
                var literal = ""
                while cursor < characters.count, characters[cursor] != "\"" {
                    let isEscape = characters[cursor] == "\\"
                    if isEscape { cursor += 1 }
                    if cursor < characters.count { literal.append(characters[cursor]) }
                    cursor += 1
                }
                if expectingKey, case .object(let slot)? = stack.last {
                    orders[slot].append(literal)
                    expectingKey = false
                }
                index = cursor + 1
                continue
            }
            if character == "{" {
                orders.append([])
                stack.append(.object(orders.count - 1))
                expectingKey = true
            } else if character == "[" {
                stack.append(.array)
                expectingKey = false
            } else if character == "}" || character == "]" {
                if !stack.isEmpty { stack.removeLast() }
                expectingKey = false
            } else if character == "," {
                if case .object? = stack.last { expectingKey = true }
            }
            index += 1
        }
        return orders
    }

    // MARK: - Binary discovery

    static let binaryPath: String = {
        let override = ProcessInfo.processInfo.environment["HUMAN_REVIEW_BIN"] ?? ""
        if !override.isEmpty { return override }
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let debugBuild = repositoryRoot.appendingPathComponent(".build/debug/human-review").path
        let releaseBuild = repositoryRoot.appendingPathComponent(".build/release/human-review").path
        if FileManager.default.isExecutableFile(atPath: debugBuild) { return debugBuild }
        if FileManager.default.isExecutableFile(atPath: releaseBuild) { return releaseBuild }
        return debugBuild
    }()
}

final class TextAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = ""

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func append(_ chunk: String) {
        lock.lock(); storage += chunk; lock.unlock()
    }
}

@Suite("binary under test")
struct BinaryDiscoveryTests {

    @Test func testTheBuiltBinaryIsPresentAndExecutable() {
        #expect(FileManager.default.isExecutableFile(atPath: ReviewCLIFixture.binaryPath),
                "no human-review binary at \(ReviewCLIFixture.binaryPath) — run `swift build` first, or set HUMAN_REVIEW_BIN")
    }
}
