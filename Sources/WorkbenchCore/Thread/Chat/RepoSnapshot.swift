import Foundation

/// What was written for the chat's agent to read, and what was left out.
public struct RepoSnapshot: Sendable, Equatable {
    /// The folder it is in, inside the agent's working folder.
    public static let folderName = "repo"
    public var commit: String
    public var files: Int
    public var bytes: Int
    /// Tracked files that are not in the folder: too large, a link or a submodule, or past a cap.
    public var left: Int
}

/// The repository's tracked files at one commit, written into the folder a chat's agent works in, so it can read and search the
/// code before a goal exists (docs/plan/P22-chat-feed.md, "Chat reads the repository").
///
/// It is a copy, not a worktree: no branch, no `.git`, and the repository's own index and files are not touched (a scratch index
/// holds the tree). It holds what git stores at the commit, so an uncommitted change, an untracked file and an ignored one
/// (`.env.local`) are not in it. Everything is bounded and a failure is "no snapshot", never a failed chat.
enum RepoSnapshotWriter {
    struct Limits: Sendable, Equatable {
        /// A bigger file is left out: it is not what a person asks about, and the folder is read on every turn.
        var fileBytes = 512 << 10
        var totalBytes = 64 << 20
        var files = 20_000
    }

    /// Paths handed to one `git checkout-index`, so the command line stays short however many files there are.
    private static let chunk = 200

    static func write(
        base: String, into work: URL, repo: URL, git: GitRunner, limits: Limits = Limits()
    ) async -> RepoSnapshot? {
        guard let resolved = try? await git.run(["rev-parse", "--verify", "--quiet", "\(base)^{commit}"], in: repo),
            resolved.succeeded
        else { return nil }
        let commit = resolved.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard SafeNames.isCommitSHA(commit),
            let listed = try? await git.run(["ls-tree", "-r", "-l", "-z", commit], in: repo),
            listed.succeeded, !listed.outputTruncated
        else { return nil }
        let chosen = select(listed.stdout, limits)
        guard !chosen.paths.isEmpty else { return nil }

        let folder = work.appendingPathComponent(RepoSnapshot.folderName, isDirectory: true)
        let index = FileManager.default.temporaryDirectory.appendingPathComponent("wb-snapshot-index-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: index) }
        // No config of the person's reaches the checkout: a filter (smudge, LFS) must not run to make a file for the model.
        var environment = git.environment
        environment["GIT_INDEX_FILE"] = index.path
        environment["GIT_ATTR_SOURCE"] = commit
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        let scratch = GitRunner(executable: git.executable, environment: environment, timeout: git.timeout)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            guard let read = try? await scratch.run(["read-tree", commit], in: repo), read.succeeded else {
                throw SnapshotError.git
            }
            var start = 0
            while start < chosen.paths.count {
                let part = Array(chosen.paths[start..<min(start + chunk, chosen.paths.count)])
                let out = try? await scratch.run(["checkout-index", "--prefix=\(folder.path)/", "--"] + part, in: repo)
                guard out?.succeeded == true else { throw SnapshotError.git }
                start += chunk
            }
        } catch {
            try? FileManager.default.removeItem(at: folder)
            return nil
        }
        removeLinks(in: folder)
        return RepoSnapshot(commit: commit, files: chosen.paths.count, bytes: chosen.bytes, left: chosen.left)
    }

    private enum SnapshotError: Error { case git }

    /// The regular files of a `git ls-tree -r -l -z` listing that fit the limits, in tree order. A link, a submodule, a file that
    /// is too large, a name a path should not have and anything past a cap is counted in `left`.
    struct Selection: Equatable {
        var paths: [String] = []
        var bytes = 0
        var left = 0
    }

    static func select(_ listing: String, _ limits: Limits) -> Selection {
        var picked = Selection()
        for record in listing.split(separator: "\0") {
            // `<mode> <type> <object> <size>\t<path>`, the size padded with spaces.
            guard let tab = record.firstIndex(of: "\t") else {
                picked.left += 1
                continue
            }
            let head = record[..<tab].split(separator: " ")
            let path = String(record[record.index(after: tab)...])
            guard head.count == 4, head[1] == "blob", head[0] == "100644" || head[0] == "100755", let size = Int(head[3]),
                isPlain(path), size <= limits.fileBytes, picked.paths.count < limits.files,
                picked.bytes + size <= limits.totalBytes
            else {
                picked.left += 1
                continue
            }
            picked.paths.append(path)
            picked.bytes += size
        }
        return picked
    }

    /// A relative path of ordinary names: nothing that leaves the folder, names git keeps for itself or controls the terminal.
    static func isPlain(_ path: String) -> Bool {
        guard !path.isEmpty, path.count <= 300, !path.hasPrefix("/") else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { part in
            !part.isEmpty && part != "." && part != ".." && part.lowercased() != ".git"
                && !part.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f }
        }
    }

    /// Nothing the checkout made may point out of the folder: a link is removed, whatever put it there.
    private static func removeLinks(in folder: URL) {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey]) else {
            return
        }
        for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
