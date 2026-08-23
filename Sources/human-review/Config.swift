import Foundation

/// Which config file a `config` operation reads or writes.
public enum ConfigScope {
    case global
    case local
}

/// One `section.key = value` pair from a config file.
public struct ConfigEntry {
    public let section: String
    public let key: String
    public let value: String

    public var fullKey: String { "\(section).\(key)".lowercased() }
}

/// A config file that could not be turned into entries.
public enum ConfigError: Error {
    case badLine(path: String, lineNumber: Int, text: String)
    case unreadableFile(path: String, reason: String)
    case unwritableFile(path: String, reason: String)
}

/// Git-style INI configuration for human-review: a global file plus an
/// optional per-directory file that overrides it key by key.
public enum ReviewConfig {

    public static func globalConfigPath() -> String {
        let override = ProcessInfo.processInfo.environment["HUMAN_REVIEW_CONFIG"] ?? ""
        let hasOverride = !override.isEmpty
        if hasOverride { return override }
        return (NSHomeDirectory() as NSString).appendingPathComponent(".human-reviewconfig")
    }

    /// Nearest `.human-review.config` from the working directory up to `/`.
    public static func findLocalConfigPath() -> String? {
        var directory = FileManager.default.currentDirectoryPath
        while true {
            let candidate = (directory as NSString).appendingPathComponent(".human-review.config")
            let candidateExists = FileManager.default.fileExists(atPath: candidate)
            if candidateExists { return candidate }
            let parent = (directory as NSString).deletingLastPathComponent
            let reachedRoot = parent.isEmpty || parent == directory
            if reachedRoot { return nil }
            directory = parent
        }
    }

    public static func configPath(for scope: ConfigScope) -> String {
        if scope == .global { return globalConfigPath() }
        if let found = findLocalConfigPath() { return found }
        return (FileManager.default.currentDirectoryPath as NSString)
            .appendingPathComponent(".human-review.config")
    }

    /// Entries of one file. A missing file is an empty config, not an error.
    public static func loadConfigFile(atPath path: String) throws -> [ConfigEntry] {
        let fileExists = FileManager.default.fileExists(atPath: path)
        guard fileExists else { return [] }
        let text: String
        do {
            text = try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            throw ConfigError.unreadableFile(path: path, reason: error.localizedDescription)
        }
        return try parseConfigText(text, path: path)
    }

    /// Global entries followed by local ones, so local wins key by key.
    public static func loadMergedConfig() throws -> [ConfigEntry] {
        let globalEntries = try loadConfigFile(atPath: globalConfigPath())
        let localEntries = try findLocalConfigPath().map { try loadConfigFile(atPath: $0) } ?? []
        return globalEntries + localEntries
    }

    public static func parseConfigText(_ text: String, path: String) throws -> [ConfigEntry] {
        var entries: [ConfigEntry] = []
        var currentSection: String? = nil
        for (index, rawLine) in text.components(separatedBy: "\n").enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let isSkippable = line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";")
            if isSkippable { continue }
            if let name = sectionName(of: line) {
                currentSection = name
                continue
            }
            guard let separator = line.firstIndex(of: "="), let section = currentSection else {
                throw ConfigError.badLine(path: path, lineNumber: index + 1, text: rawLine)
            }
            let key = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else {
                throw ConfigError.badLine(path: path, lineNumber: index + 1, text: rawLine)
            }
            let rawValue = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            entries.append(ConfigEntry(section: section, key: key, value: unescapeValue(rawValue)))
        }
        return entries
    }

    public static func valueForKey(_ key: String, in entries: [ConfigEntry]) -> String? {
        let wanted = key.lowercased()
        return entries.last(where: { $0.fullKey == wanted })?.value
    }

    public static func booleanForKey(_ key: String, in entries: [ConfigEntry]) -> Bool? {
        guard let raw = valueForKey(key, in: entries) else { return nil }
        return parseBoolean(raw)
    }

    public static func parseBoolean(_ raw: String) -> Bool? {
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "true", "yes", "on", "1":   return true
        case "false", "no", "off", "0":  return false
        default:                         return nil
        }
    }

    public static func setValue(_ value: String, forKey key: String, scope: ConfigScope) throws {
        let (section, name) = try splitKey(key)
        let path = configPath(for: scope)
        var lines = try readLines(atPath: path)
        let formatted = formatValueForWriting(value)
        var currentSection: String? = nil
        var lastLineOfSection: Int? = nil
        var didReplace = false

        for (index, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let isSkippable = line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";")
            if isSkippable { continue }
            if let found = sectionName(of: line) {
                currentSection = found
                let isTargetSection = found.lowercased() == section
                if isTargetSection { lastLineOfSection = index }
                continue
            }
            guard let separator = line.firstIndex(of: "="), let active = currentSection else {
                throw ConfigError.badLine(path: path, lineNumber: index + 1, text: rawLine)
            }
            let isTargetSection = active.lowercased() == section
            if isTargetSection { lastLineOfSection = index }
            let existingKey = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
            let isTargetEntry = isTargetSection && existingKey.lowercased() == name.lowercased()
            if isTargetEntry {
                lines[index] = "\t\(existingKey) = \(formatted)"
                didReplace = true
            }
        }

        let needsNewEntry = !didReplace
        if needsNewEntry, let anchor = lastLineOfSection {
            lines.insert("\t\(name) = \(formatted)", at: anchor + 1)
        } else if needsNewEntry {
            let needsBlankSeparator = !(lines.last?.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
            if needsBlankSeparator { lines.append("") }
            lines.append("[\(section)]")
            lines.append("\t\(name) = \(formatted)")
        }
        try writeLines(lines, toPath: path)
    }

    /// Removes a key. Returns false when the key was not in that file.
    public static func unsetValue(forKey key: String, scope: ConfigScope) throws -> Bool {
        let (section, name) = try splitKey(key)
        let path = configPath(for: scope)
        var lines = try readLines(atPath: path)
        var currentSection: String? = nil
        var indexesToRemove: [Int] = []

        for (index, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let isSkippable = line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";")
            if isSkippable { continue }
            if let found = sectionName(of: line) {
                currentSection = found
                continue
            }
            guard let separator = line.firstIndex(of: "="), let active = currentSection else {
                throw ConfigError.badLine(path: path, lineNumber: index + 1, text: rawLine)
            }
            let existingKey = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
            let isTargetEntry = active.lowercased() == section && existingKey.lowercased() == name.lowercased()
            if isTargetEntry { indexesToRemove.append(index) }
        }

        guard !indexesToRemove.isEmpty else { return false }
        for index in indexesToRemove.reversed() { lines.remove(at: index) }
        try writeLines(lines, toPath: path)
        return true
    }

    public static func formatValueForWriting(_ value: String) -> String {
        let needsQuoting = value.contains("\n") || value.contains("\t") || value.contains("\"")
            || value.hasPrefix(" ") || value.hasSuffix(" ")
        guard needsQuoting else { return value }
        return "\"\(escapeValue(value))\""
    }

    public static func escapeValue(_ value: String) -> String {
        var escaped = ""
        for character in value {
            switch character {
            case "\\": escaped += "\\\\"
            case "\n": escaped += "\\n"
            case "\t": escaped += "\\t"
            case "\"": escaped += "\\\""
            default:   escaped.append(character)
            }
        }
        return escaped
    }

    public static func unescapeValue(_ raw: String) -> String {
        let isQuoted = raw.count >= 2 && raw.hasPrefix("\"") && raw.hasSuffix("\"")
        guard isQuoted else { return raw }
        var unescaped = ""
        var isEscaping = false
        for character in raw.dropFirst().dropLast() {
            if isEscaping {
                switch character {
                case "n":  unescaped.append("\n")
                case "t":  unescaped.append("\t")
                case "\\": unescaped.append("\\")
                case "\"": unescaped.append("\"")
                default:   unescaped.append(character)
                }
                isEscaping = false
            } else if character == "\\" {
                isEscaping = true
            } else {
                unescaped.append(character)
            }
        }
        return unescaped
    }

    private static func sectionName(of line: String) -> String? {
        guard line.hasPrefix("[") && line.hasSuffix("]") else { return nil }
        return String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
    }

    private static func splitKey(_ key: String) throws -> (section: String, name: String) {
        let parts = key.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let isTwoParts = parts.count == 2 && !parts[0].isEmpty && !parts[1].isEmpty
        guard isTwoParts else {
            throw ConfigError.badLine(path: "<key>", lineNumber: 0, text: key)
        }
        return (String(parts[0]).lowercased(), String(parts[1]))
    }

    private static func readLines(atPath path: String) throws -> [String] {
        let fileExists = FileManager.default.fileExists(atPath: path)
        guard fileExists else { return [] }
        let text: String
        do {
            text = try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            throw ConfigError.unreadableFile(path: path, reason: error.localizedDescription)
        }
        var lines = text.components(separatedBy: "\n")
        let endsWithNewline = lines.count > 1 && lines.last?.isEmpty == true
        if endsWithNewline { lines.removeLast() }
        return lines
    }

    private static func writeLines(_ lines: [String], toPath path: String) throws {
        let url = URL(fileURLWithPath: path)
        let text = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url, options: .atomic)
        } catch {
            throw ConfigError.unwritableFile(path: path, reason: error.localizedDescription)
        }
    }
}

/// The user's review preferences: the effective prompt text and the stderr
/// banner that shows it to an agent on every other subcommand.
public enum Preferences {

    public enum EffectivePrompt {
        case text(String)
        case unreadableFile(String)
        case none
    }

    public static let bannerFreeSubcommands: Set<String> = ["config", "prompt", "help", "-h", "--help"]

    private static var didWriteBanner = false

    /// Writes the preferences banner once per process, unless this invocation
    /// or the configuration suppresses it.
    public static func writeBannerToStandardError(_ args: [String]) {
        let isBannerFreeSubcommand = args.first.map { bannerFreeSubcommands.contains($0) } ?? true
        let shouldSkipBanner = didWriteBanner || isBannerFreeSubcommand || isPromptSuppressed(args)
        guard !shouldSkipBanner else { return }

        let entries = loadConfigOrExit()
        guard !isQuietRequested(in: entries) else { return }

        switch resolveEffectivePrompt(from: entries) {
        case .text(let prompt):
            didWriteBanner = true
            let banner = """
            ── human-review · your review preferences (config global.prompt) ──
            \(prompt)
            ── follow these when you reply to comments ──

            """
            FileHandle.standardError.write(Data(banner.utf8))
        case .unreadableFile(let path):
            writeUnreadablePromptFile(path)
        case .none:
            break
        }
    }

    /// Reads the prompt from `global.promptFile`, else `global.prompt`.
    public static func resolveEffectivePrompt(from entries: [ConfigEntry]) -> EffectivePrompt {
        let configuredFile = ReviewConfig.valueForKey("global.promptFile", in: entries) ?? ""
        let hasPromptFile = !configuredFile.isEmpty
        if hasPromptFile {
            let path = (configuredFile as NSString).expandingTildeInPath
            guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
                return .unreadableFile(path)
            }
            return promptFromText(contents)
        }
        let inline = ReviewConfig.valueForKey("global.prompt", in: entries) ?? ""
        return promptFromText(inline)
    }

    public static func runPromptCommand(_ args: [String]) -> Int32 {
        let entries = loadConfigOrExit()
        switch resolveEffectivePrompt(from: entries) {
        case .text(let prompt):
            print(prompt)
            return 0
        case .unreadableFile(let path):
            writeUnreadablePromptFile(path)
            return 1
        case .none:
            FileHandle.standardError.write(Data("human-review: no review prompt configured (set config global.prompt or global.promptFile)\n".utf8))
            return 1
        }
    }

    private static func promptFromText(_ text: String) -> EffectivePrompt {
        let trimmed = trimTrailingWhitespace(text)
        let hasText = !trimmed.isEmpty
        if hasText { return .text(trimmed) }
        return .none
    }

    private static func trimTrailingWhitespace(_ text: String) -> String {
        var trimmed = Substring(text)
        while let last = trimmed.last, last.isWhitespace { trimmed = trimmed.dropLast() }
        return String(trimmed)
    }

    private static func isPromptSuppressed(_ args: [String]) -> Bool {
        let hasNoPromptFlag = args.contains("--no-prompt")
        if hasNoPromptFlag { return true }
        let environmentValue = ProcessInfo.processInfo.environment["HUMAN_REVIEW_NO_PROMPT"] ?? ""
        return !environmentValue.isEmpty && environmentValue != "0"
    }

    private static func writeUnreadablePromptFile(_ path: String) {
        FileHandle.standardError.write(Data("human-review: config global.promptFile unreadable: \(path)\n".utf8))
    }

    private static func isQuietRequested(in entries: [ConfigEntry]) -> Bool {
        guard let raw = ReviewConfig.valueForKey("global.promptQuiet", in: entries) else { return false }
        if let parsed = ReviewConfig.parseBoolean(raw) { return parsed }
        FileHandle.standardError.write(Data(
            "human-review: config global.promptQuiet is not a boolean: \"\(raw)\" — showing the banner\n".utf8))
        return false
    }

    private static func loadConfigOrExit() -> [ConfigEntry] {
        do {
            return try ReviewConfig.loadMergedConfig()
        } catch {
            reportConfigErrorAndExit(error)
        }
    }
}

extension ReviewConfig {

    /// The `human-review config` subcommand. Reads default to the merged
    /// config, writes default to the global file.
    public static func runConfigCommand(_ args: [String]) -> Int32 {
        let wantsGlobalScope = args.contains("--global")
        let wantsLocalScope = args.contains("--local")
        let hasBothScopes = wantsGlobalScope && wantsLocalScope
        if hasBothScopes {
            FileHandle.standardError.write(Data("human-review: --global and --local are mutually exclusive\n".utf8))
            return 2
        }
        var requestedScope: ConfigScope? = nil
        if wantsGlobalScope { requestedScope = .global }
        else if wantsLocalScope { requestedScope = .local }

        if args.contains("--list") { return listEntries(scope: requestedScope) }
        if args.contains("--path") { return printConfigPath(scope: requestedScope) }
        if args.contains("--edit") { return openConfigInEditor(scope: requestedScope) }

        let positionals = args.filter { !$0.hasPrefix("--") }
        if args.contains("--unset") {
            guard let key = positionals.first else {
                FileHandle.standardError.write(Data("human-review: --unset needs a key\n".utf8))
                return 2
            }
            return removeValue(key, scope: requestedScope ?? .global)
        }
        guard let key = positionals.first else {
            FileHandle.standardError.write(Data("usage: human-review config [--global|--local] KEY [VALUE] | --unset KEY | --list | --path | --edit\n".utf8))
            return 2
        }
        if positionals.count >= 2 { return storeValue(key, to: positionals[1], scope: requestedScope ?? .global) }
        return printEffectiveValue(key, scope: requestedScope)
    }

    private static func printEffectiveValue(_ key: String, scope: ConfigScope?) -> Int32 {
        let entries = loadEntriesOrExit(scope: scope)
        guard let value = ReviewConfig.valueForKey(key, in: entries) else { return 1 }
        print(value)
        return 0
    }

    private static func storeValue(_ key: String, to value: String, scope: ConfigScope) -> Int32 {
        do {
            try ReviewConfig.setValue(value, forKey: key, scope: scope)
            return 0
        } catch {
            reportConfigErrorAndExit(error)
        }
    }

    private static func removeValue(_ key: String, scope: ConfigScope) -> Int32 {
        do {
            let didRemove = try ReviewConfig.unsetValue(forKey: key, scope: scope)
            return didRemove ? 0 : 1
        } catch {
            reportConfigErrorAndExit(error)
        }
    }

    private static func listEntries(scope: ConfigScope?) -> Int32 {
        let entries = loadEntriesOrExit(scope: scope)
        var merged: [String: String] = [:]
        for entry in entries { merged[entry.fullKey] = entry.value }
        for key in merged.keys.sorted() {
            print("\(key)=\(ReviewConfig.escapeValue(merged[key] ?? ""))")
        }
        return 0
    }

    private static func printConfigPath(scope: ConfigScope?) -> Int32 {
        print(ReviewConfig.configPath(for: scope ?? .global))
        return 0
    }

    private static func openConfigInEditor(scope: ConfigScope?) -> Int32 {
        let path = ReviewConfig.configPath(for: scope ?? .global)
        let url = URL(fileURLWithPath: path)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
        } catch {
            FileHandle.standardError.write(Data("human-review: cannot create \(url.deletingLastPathComponent().path): \(error.localizedDescription)\n".utf8))
            return 1
        }
        let fileExists = FileManager.default.fileExists(atPath: path)
        if !fileExists { FileManager.default.createFile(atPath: path, contents: nil) }

        let environment = ProcessInfo.processInfo.environment
        var editor = environment["VISUAL"] ?? ""
        if editor.isEmpty { editor = environment["EDITOR"] ?? "" }
        if editor.isEmpty { editor = "vi" }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "\(editor) \"$1\"", "sh", path]
        do {
            try task.run()
        } catch {
            FileHandle.standardError.write(Data("human-review: cannot run editor \(editor): \(error.localizedDescription)\n".utf8))
            return 1
        }
        task.waitUntilExit()
        return task.terminationStatus
    }

    private static func loadEntriesOrExit(scope: ConfigScope?) -> [ConfigEntry] {
        do {
            guard let scope else { return try ReviewConfig.loadMergedConfig() }
            return try ReviewConfig.loadConfigFile(atPath: ReviewConfig.configPath(for: scope))
        } catch {
            reportConfigErrorAndExit(error)
        }
    }
}

func reportConfigErrorAndExit(_ error: Error) -> Never {
    switch error {
    case ConfigError.badLine(let path, let lineNumber, let text) where lineNumber > 0:
        FileHandle.standardError.write(Data("human-review: bad config line \(path):\(lineNumber): \(text)\n".utf8))
    case ConfigError.badLine(_, _, let text):
        FileHandle.standardError.write(Data("human-review: bad config key: \(text)\n".utf8))
    case ConfigError.unreadableFile(let path, let reason):
        FileHandle.standardError.write(Data("human-review: cannot read config \(path): \(reason)\n".utf8))
    case ConfigError.unwritableFile(let path, let reason):
        FileHandle.standardError.write(Data("human-review: cannot write config \(path): \(reason)\n".utf8))
    default:
        FileHandle.standardError.write(Data("human-review: config error: \(error.localizedDescription)\n".utf8))
    }
    exit(2)
}
