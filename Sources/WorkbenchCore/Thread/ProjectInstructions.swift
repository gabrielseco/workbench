import CryptoKit
import Foundation

/// The project's own instructions file (`AGENTS.md`, else `CLAUDE.md`), read from the commit a thread was
/// cut from and expanded into the first prompt. A run starts in safe mode and never sees the file
/// otherwise.
public struct ProjectInstructions: Sendable, Equatable {
    public static let sizeLimit = 16384
    public static let blobReadLimit = 64 << 10
    public static let maxImportDepth = 3
    public static let candidates = ["AGENTS.md", "CLAUDE.md"]
    public static let truncationMarker = "[project instructions truncated at \(sizeLimit) bytes]"

    public var file: String
    public var text: String
    public var sha256: String
    public var bytes: Int
    public var truncated: Bool
    /// Import lines that were left as written, each as `path: reason`.
    public var skipped: [String]

    public var eventData: JSONValue {
        [
            "file": .string(file), "sha256": .string(sha256), "bytes": .int(bytes),
            "truncated": .bool(truncated), "skipped": .array(skipped.map { .string($0) }),
        ]
    }

    /// Reads the instructions at `commit`, or nil when the commit has neither file as a regular file.
    public static func load(git: GitRunner, repo: URL, commit: String) async -> ProjectInstructions? {
        let reader = BlobReader(git: git, repo: repo, commit: commit)
        for name in candidates {
            guard let top = await reader.read(name) else { continue }
            var state = Expansion(reader: reader)
            state.visited.insert(name)
            let lines = await state.expand(top, directory: "", depth: 0)
            return finish(file: name, text: lines.joined(separator: "\n"), skipped: state.skipped)
        }
        return nil
    }

    // MARK: Internals

    static func finish(file: String, text raw: String, skipped: [String]) -> ProjectInstructions {
        var text = raw.trimmingCharacters(in: .newlines)
        var truncated = false
        if text.utf8.count > sizeLimit {
            truncated = true
            let marker = truncationMarker
            let budget = sizeLimit - marker.utf8.count - 1
            let window = Array(text.utf8.prefix(budget))
            let cut = window.lastIndex(of: UInt8(ascii: "\n")) ?? 0
            let kept = String(decoding: window[..<cut], as: UTF8.self)
            text = kept.isEmpty ? marker : kept + "\n" + marker
        }
        let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        return ProjectInstructions(
            file: file, text: text, sha256: digest, bytes: text.utf8.count, truncated: truncated,
            skipped: skipped)
    }

    /// Reads regular files out of a commit with `git ls-tree` and `git cat-file`, so nothing in a working
    /// tree (a symlink, a pipe, an edit by the run) can reach the prompt.
    struct BlobReader {
        let git: GitRunner
        let repo: URL
        let commit: String

        func read(_ path: String) async -> String? {
            guard
                let tree = try? await git.run(["ls-tree", "-z", commit, "--", path], in: repo),
                tree.succeeded
            else { return nil }
            // "<mode> <type> <sha>\t<path>" ; one record for an exact file path.
            guard let record = tree.stdout.split(separator: "\0").first,
                let tab = record.firstIndex(of: "\t")
            else { return nil }
            let fields = record[..<tab].split(separator: " ")
            guard fields.count == 3, fields[1] == "blob", fields[0] == "100644" || fields[0] == "100755",
                String(record[record.index(after: tab)...]) == path
            else { return nil }
            guard
                let blob = try? await git.run(["cat-file", "blob", String(fields[2])], in: repo),
                blob.succeeded
            else { return nil }
            let data = Data(blob.stdout.utf8.prefix(blobReadLimit))
            var text = String(decoding: data, as: UTF8.self)
            if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
            return text.replacingOccurrences(of: "\r\n", with: "\n")
        }
    }

    struct Expansion {
        let reader: BlobReader
        var visited: Set<String> = []
        var skipped: [String] = []

        mutating func expand(_ text: String, directory: String, depth: Int) async -> [String] {
            var out: [String] = []
            var fence: Character?
            for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if let marker = trimmed.first, marker == "`" || marker == "~", trimmed.hasPrefix(String(repeating: marker, count: 3)) {
                    if fence == nil { fence = marker } else if fence == marker { fence = nil }
                    out.append(line)
                    continue
                }
                guard fence == nil, trimmed.hasPrefix("@"), trimmed.count > 1,
                    !trimmed.contains(where: \.isWhitespace)
                else {
                    out.append(line)
                    continue
                }
                let requested = String(trimmed.dropFirst())
                switch await resolve(requested, directory: directory, depth: depth) {
                case .success(let (path, content)):
                    let nested = (path as NSString).deletingLastPathComponent
                    var body = content
                    while body.hasSuffix("\n") { body.removeLast() }
                    out += await expand(body, directory: nested, depth: depth + 1)
                case .failure(let reason):
                    skipped.append("\(requested): \(reason.rawValue)")
                    out.append(line)
                }
            }
            return out
        }

        enum Refusal: String, Error {
            case absolute = "absolute path"
            case escapes = "outside the repository"
            case tooDeep = "import depth over 3"
            case seen = "already included"
            case notAFile = "not a regular file in the base commit"
        }

        private mutating func resolve(_ requested: String, directory: String, depth: Int) async
            -> Result<(String, String), Refusal>
        {
            if requested.hasPrefix("/") || requested.hasPrefix("~") { return .failure(.absolute) }
            if depth >= ProjectInstructions.maxImportDepth { return .failure(.tooDeep) }
            var parts: [Substring] = directory.split(separator: "/")
            for piece in requested.split(separator: "/") {
                switch piece {
                case ".": continue
                case "..":
                    guard !parts.isEmpty else { return .failure(.escapes) }
                    parts.removeLast()
                default: parts.append(piece)
                }
            }
            let path = parts.joined(separator: "/")
            if path.isEmpty { return .failure(.notAFile) }
            if visited.contains(path) { return .failure(.seen) }
            visited.insert(path)
            guard let content = await reader.read(path) else { return .failure(.notAFile) }
            return .success((path, content))
        }
    }
}
