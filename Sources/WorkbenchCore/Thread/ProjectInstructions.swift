import CryptoKit
import Foundation

/// The project's own instructions (`AGENTS.md`, else `CLAUDE.md`) as sent in a prompt built from the goal
/// (docs/spec/goal-file.md, "Project instructions").
public struct ProjectInstructions: Sendable, Equatable {
    public enum SkipReason: String, Error, Sendable, Equatable {
        case absolute
        case outsideWorktree = "outside_worktree"
        case missing
        case symlink
        case notAFile = "not_a_file"
        case alreadyIncluded = "already_included"
        case tooDeep = "too_deep"
        case tooMany = "too_many"
    }

    public struct Skipped: Sendable, Equatable {
        /// The import as written, without the `@`.
        public var path: String
        public var reason: SkipReason
    }

    /// `AGENTS.md` or `CLAUDE.md`.
    public var file: String
    /// What goes in the prompt: imports expanded, capped, with the marker line when cut.
    public var text: String
    public var truncated: Bool
    public var skipped: [Skipped]

    public var bytes: Int { text.utf8.count }

    public var sha256: String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The `instructions` field of `turn.started`.
    var eventValue: JSONValue {
        [
            "file": .string(file), "sha256": .string(sha256), "bytes": .int(bytes),
            "truncated": .bool(truncated), "skipped": .array(skipped.map { .string($0.path) }),
        ]
    }
}

/// Reads the instructions file from one commit, through git. Never from the filesystem: the main checkout
/// may have moved on and the worktree is where Claude edits.
public struct ProjectInstructionsLoader: Sendable {
    public static let candidates = ["AGENTS.md", "CLAUDE.md"]
    public static let blobLimit = 64 << 10
    public static let textLimit = 16384
    public static let maxDepth = 3
    /// Each import costs two git commands, so their number is bounded too.
    public static let maxImports = 32
    public static let truncationMarker = "[project instructions truncated at \(textLimit) bytes]"

    private let git: GitRunner
    private let repo: URL
    private let commit: String

    /// `nil` unless `commit` is a full object id: it goes into git arguments.
    public init?(git: GitRunner, repo: URL, commit: String) {
        guard SafeNames.isCommitID(commit) else { return nil }
        self.git = git
        self.repo = repo
        self.commit = commit
    }

    public func load() async throws -> ProjectInstructions? {
        for file in Self.candidates {
            guard case .file = try await entry(file) else { continue }
            var expansion = Expansion(seen: [file])
            let lines = try await expand(try await blob(file), at: file, depth: 0, into: &expansion)
            let (text, truncated) = Self.capped(lines.joined(separator: "\n"))
            return ProjectInstructions(file: file, text: text, truncated: truncated, skipped: expansion.skipped)
        }
        return nil
    }

    // MARK: Imports

    private struct Expansion {
        var seen: Set<String>
        var skipped: [ProjectInstructions.Skipped] = []
        var imports = 0
        var bytes = 0
    }

    private func expand(
        _ text: String, at path: String, depth: Int, into expansion: inout Expansion
    ) async throws -> [String] {
        var out: [String] = []
        var fence: Character?
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }

        for line in lines {
            let indented = line.drop { $0 == " " }
            if let open = fence {
                if indented.hasPrefix(String(repeating: open, count: 3)) { fence = nil }
            } else if indented.hasPrefix("```") || indented.hasPrefix("~~~") {
                fence = indented.first
            } else if expansion.bytes <= Self.textLimit, let written = Self.importPath(in: line) {
                // Past the cap nothing more is read: the text is cut there anyway.
                switch try await resolve(written, from: path, depth: depth, expansion: &expansion) {
                case .success(let target):
                    expansion.seen.insert(target)
                    expansion.imports += 1
                    out += try await expand(try await blob(target), at: target, depth: depth + 1, into: &expansion)
                    continue
                case .failure(let reason):
                    expansion.skipped.append(.init(path: written, reason: reason))
                }
            }
            expansion.bytes += line.utf8.count + 1
            out.append(line)
        }
        return out
    }

    /// The path of a line that is exactly `@<path>`.
    static func importPath(in line: String) -> String? {
        guard line.hasPrefix("@"), line.count > 1, !line.contains(where: \.isWhitespace) else { return nil }
        return String(line.dropFirst())
    }

    private typealias Resolved = Result<String, ProjectInstructions.SkipReason>

    private func resolve(
        _ written: String, from importer: String, depth: Int, expansion: inout Expansion
    ) async throws -> Resolved {
        let lexical = Self.normalized(written, relativeTo: importer)
        guard case .success(let target) = lexical else { return lexical }
        if expansion.seen.contains(target) { return .failure(.alreadyIncluded) }
        if depth >= Self.maxDepth { return .failure(.tooDeep) }
        if expansion.imports >= Self.maxImports { return .failure(.tooMany) }
        switch try await entry(target) {
        case .file: return .success(target)
        case .symlink: return .failure(.symlink)
        case .other: return .failure(.notAFile)
        case .missing: return .failure(.missing)
        }
    }

    /// The repository-relative path an import names, or why it cannot be followed. Purely lexical: the
    /// tree lookup that follows never passes through a symlink, so nothing here can leave the commit.
    static func normalized(
        _ written: String, relativeTo importer: String
    ) -> Result<String, ProjectInstructions.SkipReason> {
        if written.hasPrefix("/") || written.hasPrefix("~") { return .failure(.absolute) }
        if written.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f || $0 == "\\" }) {
            return .failure(.missing)
        }
        var parts = importer.split(separator: "/").dropLast().map(String.init)
        for part in written.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..":
                if parts.isEmpty { return .failure(.outsideWorktree) }
                parts.removeLast()
            default: parts.append(String(part))
            }
        }
        if parts.isEmpty { return .failure(.notAFile) }
        return .success(parts.joined(separator: "/"))
    }

    // MARK: Git

    private enum Entry {
        case file
        case symlink
        case other
        case missing
    }

    /// What `path` is in the commit. Only called with a top-level candidate or a `normalized` path.
    private func entry(_ path: String) async throws -> Entry {
        let result = try await git.run(["--literal-pathspecs", "ls-tree", "-z", commit, "--", path], in: repo)
        guard result.succeeded else { return .missing }
        // `<mode> <type> <object>\t<path>\0`
        let fields = result.stdout.prefix { $0 != "\t" }.split(separator: " ")
        guard fields.count == 3 else { return .missing }
        switch (fields[0], fields[1]) {
        case ("100644", "blob"), ("100755", "blob"): return .file
        case ("120000", _): return .symlink
        default: return .other
        }
    }

    private func blob(_ path: String) async throws -> String {
        let result = try await git.run(["show", "\(commit):\(path)"], in: repo, outputLimit: Self.blobLimit)
        guard result.succeeded else { return "" }
        return Self.cleaned(result.stdout)
    }

    // MARK: Text

    /// `GitRunner` already replaced invalid UTF-8; this drops a leading BOM and turns CRLF into LF.
    static func cleaned(_ text: String) -> String {
        var scalars = Substring(text).unicodeScalars
        if scalars.first == "\u{FEFF}" { scalars.removeFirst() }
        return String(scalars).replacingOccurrences(of: "\r\n", with: "\n")
    }

    /// At most `textLimit` bytes of `text`, cut at a line boundary, then the marker line.
    static func capped(_ text: String) -> (text: String, truncated: Bool) {
        let bytes = Array(text.utf8)
        guard bytes.count > textLimit else { return (text, false) }
        var end = textLimit
        if let newline = bytes[..<(textLimit + 1)].lastIndex(of: UInt8(ascii: "\n")) {
            end = newline
        } else {
            // One line longer than the cap: cut it, but not inside a character.
            while end > 0, bytes[end] & 0xC0 == 0x80 { end -= 1 }
        }
        let kept = String(decoding: bytes[..<end], as: UTF8.self)
        return (kept + (kept.isEmpty ? "" : "\n") + truncationMarker, true)
    }
}
