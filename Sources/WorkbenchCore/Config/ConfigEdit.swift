import Foundation

/// Changes one agent key in a project's `.workbench/config.toml` (`agents.<role>.provider`, `.model`, `.reasoning_effort`) and nothing
/// else: every other line, comment and table stays where it was. The result is parsed as a config before anything is written, so a
/// value the config would not load leaves the file exactly as it was. One writer of the config: `GoalAgentSetup` calls it too.
public enum ConfigEdit {
    /// A config bigger than this is not read into memory to be edited.
    static let limit = 256 * 1024

    public enum Field: String, Sendable, CaseIterable {
        case provider
        case model
        case reasoningEffort = "reasoning_effort"
    }

    public struct Key: Sendable, Equatable, CustomStringConvertible {
        public var role: AgentRole
        public var field: Field
        public var description: String { "agents.\(role.rawValue).\(field.rawValue)" }
        public init(role: AgentRole, field: Field) {
            self.role = role
            self.field = field
        }

        var table: String { "agents.\(role.rawValue)" }
    }

    /// What a successful edit did: the key's value before and after (nil is not set).
    public struct Change: Sendable, Equatable {
        public var key: Key
        public var old: String?
        public var new: String?
        public var written: Bool { old != new }
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case badKey(String)
        case badValue(Key, String)
        case notSet(Key)
        case noConfig
        case doesNotLoad(String)
        case tooLarge
        case unsafe(String)
        case invalid(String)
        case notWritten(String)
        case changed

        public var description: String {
            switch self {
            case .badKey(let text):
                "'\(text)' is not a key this can change: use agents.<role>.<provider|model|reasoning_effort>, with <role> one of "
                    + AgentRole.allCases.map(\.rawValue).joined(separator: ", ") + "."
            case .badValue(let key, let why): "'\(key)' cannot be set to that: \(why)"
            case .notSet(let key): "\(key) is not set in the config, so there is nothing to remove."
            case .noConfig: "this project has no .workbench/config.toml yet: run `workbench init` first."
            case .doesNotLoad(let why): "the config does not load as it is, so it was not touched: \(why)"
            case .tooLarge: "the config is over \(limit / 1024) KiB: change it by hand."
            case .unsafe(let why): "the config was not touched: \(why). Change it by hand."
            case .invalid(let why): "the config would not load with that change, so it was left as it was: \(why)"
            case .notWritten(let why): "the config could not be written: \(why)"
            case .changed: "the config changed while it was being edited, so nothing was written: run the command again."
            }
        }
    }

    /// `agents.goal.provider` to a key.
    public static func parseKey(_ text: String) throws -> Key {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[0] == "agents", let role = AgentRole(rawValue: parts[1]),
            let field = Field(rawValue: parts[2])
        else { throw Failure.badKey(text) }
        return Key(role: role, field: field)
    }

    /// A value is a plain name: it is written between quotes as it is, so it can hold no quote, backslash, space or newline.
    static func checkValue(_ value: String, for key: Key) throws {
        guard value.range(of: #"^[A-Za-z0-9._:/@\[\]-]{1,100}$"#, options: .regularExpression) != nil else {
            throw Failure.badValue(key, "a name of letters, digits and . _ : / @ [ ] -, up to 100 characters")
        }
    }

    public static func set(_ key: Key, to value: String, in project: Project) throws -> Change {
        try checkValue(value, for: key)
        return try edit(key, value: value, in: project, beforeWrite: {})
    }

    public static func unset(_ key: Key, in project: Project) throws -> Change {
        try edit(key, value: nil, in: project, beforeWrite: {})
    }

    /// `beforeWrite` runs between the last read and the write: a test changes the file there.
    static func edit(_ key: Key, value: String?, in project: Project, beforeWrite: () -> Void) throws -> Change {
        let url = project.configURL
        // Two edits at once would each read the same file and the second write would lose the first: one at a time. The lock is
        // on the folder, which is never replaced or removed, so no edit ever waits on a lock another has deleted.
        let lock = open(url.deletingLastPathComponent().path, O_RDONLY)
        guard lock >= 0, flock(lock, LOCK_EX) == 0 else {
            if lock >= 0 { close(lock) }
            throw Failure.notWritten("could not lock the config: \(String(cString: strerror(errno)))")
        }
        defer {
            flock(lock, LOCK_UN)
            close(lock)
        }
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int else {
            throw Failure.noConfig
        }
        guard size <= limit else { throw Failure.tooLarge }
        guard let original = try? String(contentsOf: url, encoding: .utf8) else { throw Failure.noConfig }
        guard !original.utf8.contains(13) else { throw Failure.unsafe("it has Windows line endings") }
        let before: TOMLDocument
        do {
            _ = try Config.parse(original)
            before = TOMLSubset.parse(original).document
        } catch {
            throw Failure.doesNotLoad("\(error)")
        }
        let old = stringValue(before, key)
        if value == nil, old == nil { throw Failure.notSet(key) }
        if old == value { return Change(key: key, old: old, new: value) }

        let text = try rewritten(original, key: key, value: value, document: before)
        do {
            let config = try Config.parse(text)
            guard stringValue(TOMLSubset.parse(text).document, key) == value else {
                throw Failure.invalid("the key was not read back")
            }
            if key.field == .provider, let value, config.agents.selection(key.role).provider?.rawValue != value {
                throw Failure.invalid("the provider was not read back")
            }
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.invalid("\(error)")
        }

        beforeWrite()
        // A change between the read and now is somebody else's: it is not overwritten.
        guard (try? String(contentsOf: url, encoding: .utf8)) == original else { throw Failure.changed }
        do {
            let mode = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions]
            try text.write(to: url, atomically: true, encoding: .utf8)
            if let mode { try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path) }
        } catch {
            throw Failure.notWritten("\(error)")
        }
        return Change(key: key, old: old, new: value)
    }

    private static func stringValue(_ document: TOMLDocument, _ key: Key) -> String? {
        guard case .string(let value) = document.tables[key.table]?.entries[key.field.rawValue]?.value else { return nil }
        return value
    }

    /// The text with the key set (a line changed, added to its table, or the table appended) or removed.
    private static func rewritten(_ text: String, key: Key, value: String?, document: TOMLDocument) throws -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let hadFinalNewline = text.hasSuffix("\n")
        if hadFinalNewline { lines.removeLast() }
        let name = key.field.rawValue
        guard let table = document.tables[key.table] else {
            guard let value else { throw Failure.notSet(key) }
            var out = text
            if !out.isEmpty { out += hadFinalNewline ? "\n" : "\n\n" }
            return out + "[\(key.table)]\n\(name) = \"\(value)\"\n"
        }
        let start = table.line - 1
        let next = document.tables.values.map(\.line).filter { $0 > table.line }.min().map { $0 - 1 } ?? lines.count
        guard start < lines.count, next <= lines.count else {
            throw Failure.unsafe("the [\(key.table)] table could not be placed")
        }

        if let entry = table.entries[name] {
            let index = entry.line - 1
            guard index > start, index < next else { throw Failure.unsafe("the key '\(name)' could not be placed") }
            guard let value else {
                // A comment on the key's line stays as a line of its own.
                if let at = commentStart(lines[index]) {
                    lines[index] = String(lines[index].dropFirst(at))
                } else {
                    lines.remove(at: index)
                }
                dropEmptyTable(&lines, header: start, document: document, key: key)
                return join(lines, finalNewline: hadFinalNewline)
            }
            lines[index] = replacing(lines[index], name: name, value: value)
        } else if let value {
            // After the table's last line of content: the blank lines and comments above the next table belong to it.
            var last = next - 1
            while last > start, isBlankOrComment(lines[last]) { last -= 1 }
            lines.insert("\(name) = \"\(value)\"", at: last + 1)
        }
        return join(lines, finalNewline: hadFinalNewline)
    }

    private static func isBlankOrComment(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed.hasPrefix("#")
    }

    /// Where a trailing `# comment` starts in a line (a `#` inside quotes is not one), or nil.
    private static func commentStart(_ line: String) -> Int? {
        var quote: Character?
        for (offset, ch) in line.enumerated() {
            if let q = quote {
                if ch == q { quote = nil }
            } else if ch == "\"" || ch == "'" {
                quote = ch
            } else if ch == "#" {
                return offset
            }
        }
        return nil
    }

    /// `key = "old"  # why` keeps its indent and its comment, with the space before it as it was.
    private static func replacing(_ line: String, name: String, value: String) -> String {
        let indent = line.prefix { $0 == " " || $0 == "\t" }
        var comment = ""
        if let at = commentStart(line) {
            let gap = line.prefix(at).reversed().prefix { $0 == " " || $0 == "\t" }
            comment = String(gap.reversed()) + String(line.dropFirst(at))
        }
        return "\(indent)\(name) = \"\(value)\"\(comment)"
    }

    /// The table the last key was taken out of goes too, with its header: a comment on the header line or inside the table stays as a
    /// line of its own, and one blank line next to the header goes with it so the gap is not doubled.
    private static func dropEmptyTable(_ lines: inout [String], header: Int, document: TOMLDocument, key: Key) {
        guard let table = document.tables[key.table], table.entries.count == 1 else { return }
        if let at = commentStart(lines[header]) {
            lines[header] = String(lines[header].dropFirst(at))
            return
        }
        lines.remove(at: header)
        if header > 0, lines[header - 1].trimmingCharacters(in: .whitespaces).isEmpty {
            lines.remove(at: header - 1)
        } else if header < lines.count, lines[header].trimmingCharacters(in: .whitespaces).isEmpty {
            lines.remove(at: header)
        }
    }

    private static func join(_ lines: [String], finalNewline: Bool) -> String {
        lines.joined(separator: "\n") + (finalNewline && !lines.isEmpty ? "\n" : "")
    }
}
