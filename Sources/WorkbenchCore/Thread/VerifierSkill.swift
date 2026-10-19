import CryptoKit
import Foundation

/// The verifier's instructions: the project's skill file, read from the base commit so the coding run cannot
/// change what its own verifier is told (docs/plan/P10-skill-verifier.md, rule 1).
public struct VerifierSkill: Sendable, Equatable {
    public static let sizeLimit = 32768
    public static let truncationMarker = "[verifier skill truncated at \(sizeLimit) bytes]"

    public var path: String
    public var text: String
    /// Of `text` as the model is given it, after the cut.
    public var sha256: String
    public var bytes: Int
    public var truncated: Bool

    public var eventData: JSONValue {
        ["skill": .string(path), "sha256": .string(sha256), "bytes": .int(bytes), "truncated": .bool(truncated)]
    }

    /// Why a skill cannot be used. Every case names the path, so the fix is in the message.
    public enum Problem: Error, Equatable, CustomStringConvertible {
        case missing(String)
        /// `link` is the symlink the path is, or goes through; `real` the repo-relative path to use instead, or "".
        case symlink(String, link: String, real: String)
        case tooLarge(String)
        case unreadable(String)
        case empty(String)

        public var description: String {
            switch self {
            case .missing(let path):
                "the verifier skill \(path) is not a file in the base commit; commit it first, or fix [verifier] skill"
            case .symlink(let path, let link, let real):
                "the verifier skill \(path) \(link == path ? "is" : "goes through") the symlink \(link) in the base "
                    + "commit, and git holds only a link's target path; set [verifier] skill to the real file"
                    + (real.isEmpty ? "" : ": \(real)")
            case .tooLarge(let path):
                "the verifier skill \(path) is larger than \(ProjectInstructions.blobSizeCeiling >> 20) MB"
            case .unreadable(let path): "the verifier skill \(path) could not be read from the base commit"
            case .empty(let path): "the verifier skill \(path) is empty in the base commit"
            }
        }
    }

    /// Reads `path` at `commit`. A symlink is refused with the path it points at, since git stores a link as
    /// its target text and that text would reach the model as its instructions.
    public static func load(git: GitRunner, repo: URL, commit: String, path: String) async -> Result<VerifierSkill, Problem> {
        let reader = ProjectInstructions.BlobReader(git: git, repo: repo, commit: commit)
        if let problem = await symlinkProblem(reader, path) { return .failure(problem) }
        guard let entry = await reader.entry(path) else { return .failure(.missing(path)) }
        guard entry.isRegularFile else { return .failure(.missing(path)) }
        guard let raw = await reader.contents(of: entry) else {
            return .failure(await oversized(git: git, repo: repo, sha: entry.sha) ? .tooLarge(path) : .unreadable(path))
        }
        return finish(path: path, raw: raw)
    }

    /// The path is a symlink, or sits under one (this repository's `.claude/skills/<name>` points into `.agents/`).
    private static func symlinkProblem(_ reader: ProjectInstructions.BlobReader, _ path: String) async -> Problem? {
        let parts = path.split(separator: "/").map(String.init)
        for count in 1...max(parts.count, 1) {
            let link = parts.prefix(count).joined(separator: "/")
            guard let entry = await reader.entry(link), entry.isSymlink else { continue }
            let target = await reader.contents(of: entry) ?? ""
            let base = resolve(link: target, from: link)
            let rest = parts.dropFirst(count).joined(separator: "/")
            let real = base.isEmpty ? "" : (rest.isEmpty ? base : base + "/" + rest)
            return .symlink(path, link: link, real: real)
        }
        return nil
    }

    static func finish(path: String, raw: String) -> Result<VerifierSkill, Problem> {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return .failure(.empty(path)) }
        var truncated = false
        if text.utf8.count > sizeLimit {
            truncated = true
            let budget = sizeLimit - truncationMarker.utf8.count - 1
            let window = Array(text.utf8.prefix(budget))
            let cut = window.lastIndex(of: UInt8(ascii: "\n")) ?? 0
            let kept = String(decoding: window[..<cut], as: UTF8.self)
            text = kept.isEmpty ? truncationMarker : kept + "\n" + truncationMarker
        }
        let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        return .success(
            VerifierSkill(path: path, text: text, sha256: digest, bytes: text.utf8.count, truncated: truncated))
    }

    /// The repo-relative path a symlink at `path` points to, or "" when it leaves the repository or is absolute.
    static func resolve(link target: String, from path: String) -> String {
        let target = target.trimmingCharacters(in: .whitespacesAndNewlines)
        if target.isEmpty || target.hasPrefix("/") { return "" }
        var parts = path.split(separator: "/").dropLast().map(String.init)
        for piece in target.split(separator: "/") {
            switch piece {
            case ".": continue
            case "..":
                guard !parts.isEmpty else { return "" }
                parts.removeLast()
            default: parts.append(String(piece))
            }
        }
        return parts.joined(separator: "/")
    }

    private static func oversized(git: GitRunner, repo: URL, sha: String) async -> Bool {
        guard let size = try? await git.run(["cat-file", "-s", sha], in: repo), size.succeeded,
            let bytes = Int(size.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return false }
        return bytes > ProjectInstructions.blobSizeCeiling
    }
}
