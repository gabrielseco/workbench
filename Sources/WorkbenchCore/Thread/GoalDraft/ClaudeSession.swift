import Foundation

/// A Claude Code session of this project, read as the conversation a goal is drafted from
/// (`workbench goal draft <name> --from-claude-session [<id>]`). The session is untrusted input: only the person's words and
/// the assistant's text are kept, never a tool call, a tool result, thinking, an attachment or a file snapshot.
public enum ClaudeSession {
    /// The most the rendered conversation may be: the chat's own limit.
    public static let limit = Chat.maxConversationBytes
    /// A session file larger than this is not read at all.
    static let fileLimit = 1 << 30
    /// A single line larger than this is skipped (a pasted file or a huge tool result), not parsed.
    static let lineLimit = 16 << 20

    public struct Message: Equatable, Sendable {
        public enum Role: Sendable { case person, assistant }
        public var role: Role
        public var text: String

        public init(_ role: Role, _ text: String) {
            (self.role, self.text) = (role, text)
        }
    }

    /// A Claude config directory to look in, and what named it.
    public struct Place: Equatable, Sendable {
        public var directory: URL
        public var source: String
    }

    public struct Rendered: Equatable, Sendable {
        public var id: String
        public var file: URL
        public var text: String
        /// How many messages of the session were left out to fit `limit` (the oldest, after the first of the person's).
        public var dropped: Int
    }

    // MARK: Where

    /// The places to look, in order: `claude_config_dir` of the global config, `CLAUDE_CONFIG_DIR`, then `~/.claude`.
    /// A place named twice is looked in once.
    public static func places(configured: URL?, environment: [String: String], home: String) -> [Place] {
        var places: [Place] = []
        if let configured { places.append(Place(directory: configured, source: "claude_config_dir in ~/.workbench/config.toml")) }
        if let env = environment["CLAUDE_CONFIG_DIR"], let url = GlobalConfig.expandedDirectory(env, home: home) {
            places.append(Place(directory: url, source: "CLAUDE_CONFIG_DIR"))
        }
        places.append(Place(directory: URL(fileURLWithPath: home).appendingPathComponent(".claude"), source: "~/.claude"))
        var seen: Set<String> = []
        return places.filter { seen.insert($0.directory.standardizedFileURL.path).inserted }
    }

    /// The folder name Claude Code keeps a project's sessions under: its absolute path with every character that is not an
    /// ASCII letter or digit made a `-` (`/Users/me/repo.x` is `-Users-me-repo-x`).
    public static func projectFolderName(_ path: String) -> String {
        String(path.unicodeScalars.map { scalar -> Character in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar)) ? Character(scalar) : "-"
        })
    }

    /// A session id as Claude Code makes it (a UUID): letters, digits and `-` only, so it can never become another path.
    public static func isSessionID(_ text: String) -> Bool {
        text.wholeMatch(of: #/[A-Za-z0-9][A-Za-z0-9-]{0,127}/#) != nil
    }

    /// The project's session folders in `place`: under its real path first, as Claude Code names it from its working folder
    /// (`/tmp` is `/private/tmp`; Foundation's `resolvingSymlinksInPath` would turn that back), then under the path as given.
    static func folders(project root: URL, in place: Place) -> [URL] {
        let projects = place.directory.appendingPathComponent("projects")
        let given = root.standardizedFileURL.path
        var names: [String] = []
        if let real = realpath(given, nil) {
            names.append(projectFolderName(String(cString: real)))
            free(real)
        }
        let plain = projectFolderName(given)
        if !names.contains(plain) { names.append(plain) }
        return names.map { projects.appendingPathComponent($0) }
    }

    /// The session file to draft from: the one named, or the newest of the project's. Refuses with every place it looked.
    public static func pick(id: String?, project root: URL, places: [Place]) throws -> (id: String, file: URL) {
        if let id, !isSessionID(id) { throw ClaudeSessionRefusal.invalidID(id) }
        let fm = FileManager.default
        var looked: [String] = []
        for place in places {
            for folder in folders(project: root, in: place) {
                looked.append("\(folder.path) (\(place.source))")
                if let id {
                    let file = folder.appendingPathComponent("\(id).jsonl")
                    if isRegularFile(file) { return (id, file) }
                    continue
                }
                guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { continue }
                var newest: (picked: (id: String, file: URL), date: Date)?
                for name in names where name.hasSuffix(".jsonl") {
                    let stem = String(name.dropLast(".jsonl".count))
                    let file = folder.appendingPathComponent(name)
                    guard isSessionID(stem), isRegularFile(file) else { continue }
                    let date = (try? fm.attributesOfItem(atPath: file.path)[.modificationDate] as? Date) ?? .distantPast
                    if let known = newest, known.date >= date { continue }
                    newest = ((stem, file), date)
                }
                if let newest { return newest.picked }
            }
        }
        if let id { throw ClaudeSessionRefusal.unknownID(id, looked: looked) }
        throw ClaudeSessionRefusal.noSession(looked: looked)
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
    }

    // MARK: What was said

    /// The conversation in a session file's lines: the person's messages and the assistant's text, consecutive lines of the
    /// assistant's joined into one reply. Each of the person's messages stays its own, so the first is never grown by the next
    /// (and bounding can keep it while leaving later ones out). Anything else is left out, and a line that is not a JSON
    /// object is skipped.
    public static func messages(_ data: Data) -> [Message] {
        var out: [Message] = []
        for line in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            guard line.count <= lineLimit, let message = message(Data(line)) else { continue }
            if message.role == .assistant, let last = out.last, last.role == .assistant {
                out[out.count - 1].text += "\n\n" + message.text
            } else {
                out.append(message)
            }
        }
        return out
    }

    /// What the person typed that Claude Code wraps a command, its output or a notice in: not the person's words.
    private static let wrapped = [
        "<command-name>", "<command-message>", "<command-args>", "<local-command-", "<bash-input>", "<bash-stdout>",
        "<bash-stderr>", "<task-notification>", "<system-reminder>", "<user-memory-input>", "Caveat: The messages below",
        "[Request interrupted",
    ]

    private static func message(_ line: Data) -> Message? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return nil }
        if object["isSidechain"] as? Bool == true || object["isMeta"] as? Bool == true { return nil }
        if object["toolUseResult"] != nil || object["isCompactSummary"] as? Bool == true { return nil }
        let role: Message.Role
        switch object["type"] as? String {
        case "user": role = .person
        case "assistant": role = .assistant
        default: return nil
        }
        guard let body = object["message"] as? [String: Any] else { return nil }
        var texts: [String] = []
        if let text = body["content"] as? String {
            texts = [text]
        } else if let blocks = body["content"] as? [Any] {
            // Only text blocks: a tool call, a tool result, thinking or an image is left out.
            texts = blocks.compactMap { block in
                guard let block = block as? [String: Any], block["type"] as? String == "text" else { return nil }
                return block["text"] as? String
            }
        }
        let kept = texts.map { $0.replacingOccurrences(of: "\0", with: "").trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { text in !text.isEmpty && !(role == .person && wrapped.contains { text.hasPrefix($0) }) }
        guard !kept.isEmpty else { return nil }
        return Message(role, kept.joined(separator: "\n\n"))
    }

    // MARK: Bounded

    static func render(_ message: Message) -> String {
        "\(message.role == .person ? "The person" : "The assistant") said:\n\(message.text)"
    }

    static func omitted(_ count: Int) -> String {
        "(\(count) earlier message\(count == 1 ? " was" : "s were") left out here: the session is longer than "
            + "\(limit / 1024) KiB.)"
    }

    /// The conversation as one text of at most `limit` bytes, from the person's first message. When it is longer, the oldest
    /// messages after that first one are left out, whole, and a line says how many; a message is never cut. When even that
    /// line does not fit beside the first message, it is left out too (`dropped` still counts what was).
    public static func bounded(_ messages: [Message], limit: Int = limit) throws -> (text: String, dropped: Int) {
        guard let start = messages.firstIndex(where: { $0.role == .person }) else { throw ClaudeSessionRefusal.empty }
        let first = render(messages[start])
        let rest = messages[(start + 1)...].map(render)
        let separator = 2
        guard first.utf8.count <= limit else { throw ClaudeSessionRefusal.firstTooLong }
        // sizes[k]: what rest[k...] takes, each with the separator before it.
        var sizes = [Int](repeating: 0, count: rest.count + 1)
        for k in stride(from: rest.count - 1, through: 0, by: -1) { sizes[k] = sizes[k + 1] + separator + rest[k].utf8.count }
        func note(_ count: Int) -> Int { count > 0 ? separator + omitted(count).utf8.count : 0 }
        var from = 0
        while from < rest.count, first.utf8.count + note(from) + sizes[from] > limit { from += 1 }
        var parts = [first]
        // Stopping before the end means it fitted with the line; with every later message left out, it is checked here.
        if from > 0, first.utf8.count + note(from) <= limit { parts.append(omitted(from)) }
        parts += rest[from...]
        return (parts.joined(separator: "\n\n"), from)
    }

    public static func load(id: String?, project root: URL, places: [Place]) throws -> Rendered {
        let picked = try pick(id: id, project: root, places: places)
        let data: Data
        do { data = try Data(contentsOf: picked.file, options: .alwaysMapped) } catch {
            throw ClaudeSessionRefusal.unreadable(picked.file.path, "\(error.localizedDescription)")
        }
        guard data.count <= fileLimit else { throw ClaudeSessionRefusal.unreadable(picked.file.path, "it is over 1 GiB") }
        let (text, dropped) = try bounded(messages(data))
        return Rendered(id: picked.id, file: picked.file, text: text, dropped: dropped)
    }
}

/// Why a session could not be drafted from. Nothing was spawned, spent or written.
public enum ClaudeSessionRefusal: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidID(String)
    case unknownID(String, looked: [String])
    case noSession(looked: [String])
    case unreadable(String, String)
    case empty
    case firstTooLong

    public var description: String {
        switch self {
        case .invalidID(let id):
            "'\(id)' is not a Claude Code session id (letters, digits and '-' only)."
        case .unknownID(let id, let looked):
            "no Claude Code session \(id) for this project. Looked in:\n" + Self.list(looked)
        case .noSession(let looked):
            "no Claude Code session for this project. Looked in:\n" + Self.list(looked)
        case .unreadable(let path, let why): "the session \(path) could not be read: \(why)"
        case .empty: "the session has no message of the person's to draft from."
        case .firstTooLong:
            "the session's first message is over \(ClaudeSession.limit / 1024) KiB; draft with --request-file instead."
        }
    }

    private static func list(_ looked: [String]) -> String {
        looked.map { "  \($0)" }.joined(separator: "\n")
            + "\nIf Claude Code keeps its sessions elsewhere, set claude_config_dir in ~/.workbench/config.toml "
            + "to its config folder (the one CLAUDE_CONFIG_DIR names, holding projects/)."
    }
}
