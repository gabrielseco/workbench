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
/// It is a copy, not a worktree: no branch, no `.git`, and the repository is not opened for writing at all. The files are checked out
/// by a scratch repository of their own that only borrows this repository's objects, so none of this repository's config, attributes
/// file (`.git/info/attributes`) or remotes is read: a clean or smudge filter (LFS, or one the person set) cannot run, and a repository
/// with missing objects cannot start a network fetch. It holds what git stores at the commit, so an uncommitted change, an untracked file
/// and an ignored one (`.env.local`) are not in it. Everything is bounded and a failure is "no snapshot", never a failed chat.
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
        // Looking up the commit asks the repository only for refs and the commit, and never for a missing object from a remote
        // (`GIT_NO_LAZY_FETCH`, git 2.44 and later; the listing below, which could, runs where there is no remote).
        var lookups = git.environment
        lookups["GIT_NO_LAZY_FETCH"] = "1"
        let lookup = GitRunner(executable: git.executable, environment: lookups, timeout: git.timeout)
        guard let resolved = try? await lookup.run(["rev-parse", "--verify", "--quiet", "\(base)^{commit}"], in: repo),
            resolved.succeeded
        else { return nil }
        let commit = resolved.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let found = try? await lookup.run(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: repo)
        guard SafeNames.isCommitSHA(commit), let common = found, common.succeeded else { return nil }
        let objects = common.stdout.trimmingCharacters(in: .whitespacesAndNewlines) + "/objects"

        let folder = work.appendingPathComponent(RepoSnapshot.folderName, isDirectory: true)
        let temporary = FileManager.default.temporaryDirectory
        let scratchGit = temporary.appendingPathComponent("wb-snapshot-git-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratchGit) }
        // No config of the person's reaches the checkout: not the global or system one (a smudge or LFS filter must not run to make a
        // file for the model), and not the repository's own, which is why the listing and the checkout run in a repository of their own.
        // It borrows the objects and has no remote, so a partial clone's missing object is an error here (no copy), never a fetch.
        var plain = git.environment
        plain["GIT_CONFIG_GLOBAL"] = "/dev/null"
        plain["GIT_CONFIG_NOSYSTEM"] = "1"
        plain["GIT_NO_LAZY_FETCH"] = "1"
        var checkout = plain
        checkout["GIT_DIR"] = scratchGit.path
        checkout["GIT_WORK_TREE"] = folder.path
        checkout["GIT_ALTERNATE_OBJECT_DIRECTORIES"] = objects
        checkout["GIT_ATTR_SOURCE"] = commit
        let maker = GitRunner(executable: git.executable, environment: plain, timeout: git.timeout)
        let scratch = GitRunner(executable: git.executable, environment: checkout, timeout: git.timeout)

        // The work tree git is told about has to exist; whatever is left of it is removed unless the copy is complete.
        var complete = false
        defer { if !complete { try? FileManager.default.removeItem(at: folder) } }
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil,
            let made = try? await maker.run(["init", "-q", "--bare", "--template=", scratchGit.path], in: temporary),
            made.succeeded,
            let listed = try? await scratch.run(["ls-tree", "-r", "-l", "-z", commit], in: temporary),
            listed.succeeded, !listed.outputTruncated
        else { return nil }
        let chosen = select(listed.stdout, limits)
        guard !chosen.paths.isEmpty else { return nil }

        guard let read = try? await scratch.run(["read-tree", commit], in: folder), read.succeeded else { return nil }
        var start = 0
        while start < chosen.paths.count {
            let part = Array(chosen.paths[start..<min(start + chunk, chosen.paths.count)])
            guard let out = try? await scratch.run(["checkout-index", "--"] + part, in: folder), out.succeeded else { return nil }
            start += chunk
        }
        guard keepWithinLimits(folder, limits) else { return nil }
        complete = true
        return RepoSnapshot(commit: commit, files: chosen.paths.count, bytes: chosen.bytes, left: chosen.left)
    }

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

    /// What the checkout made is checked, not trusted: a link is removed (nothing may point out of the folder), a file over the per-file
    /// limit is removed, and a folder that is over the total after any conversion is no copy at all. True when the folder may be used.
    static func keepWithinLimits(_ folder: URL, _ limits: Limits) -> Bool {
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else { return false }
        var total = 0
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isSymbolicLink == true {
                try? FileManager.default.removeItem(at: url)
            } else if values.isRegularFile == true {
                let size = values.fileSize ?? 0
                if size > limits.fileBytes {
                    try? FileManager.default.removeItem(at: url)
                } else {
                    total += size
                }
            }
        }
        return total <= limits.totalBytes
    }
}
