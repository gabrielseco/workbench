import Foundation

/// What the worktree held when a proof was taken: the commit it was on and the tree of everything in it,
/// committed or not. The tree is what a proof is about (an amend or a rebase that keeps the content does not
/// make a screenshot stale); the commit is for the person reading the log.
public struct ProofIdentity: Sendable, Equatable {
    public var commit: String
    public var tree: String

    public init(commit: String, tree: String) {
        self.commit = commit
        self.tree = tree
    }

    /// `HEAD` of `worktree` and the tree of its files as they are now: tracked changes and untracked files, not
    /// ignored ones. Built in a throwaway index, so the worktree's own index and the history are untouched.
    /// Nil when git cannot say (no commit yet, a timeout): a proof without an identity is "unknown", not stale.
    public static func of(worktree: URL, git: GitRunner) async -> ProofIdentity? {
        let index = FileManager.default.temporaryDirectory.appendingPathComponent("wb-index-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: index) }
        var environment = git.environment
        environment["GIT_INDEX_FILE"] = index.path
        let scratch = GitRunner(executable: git.executable, environment: environment, timeout: git.timeout)
        guard let head = try? await git.run(["rev-parse", "--verify", "--quiet", "HEAD"], in: worktree), head.succeeded,
            let read = try? await scratch.run(["read-tree", "HEAD"], in: worktree), read.succeeded,
            let add = try? await scratch.run(["add", "-A"], in: worktree), add.succeeded,
            let write = try? await scratch.run(["write-tree"], in: worktree), write.succeeded
        else { return nil }
        let commit = head.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let tree = write.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !commit.isEmpty, !tree.isEmpty else { return nil }
        return ProofIdentity(commit: commit, tree: tree)
    }
}

extension ProofIdentity {
    /// `HEAD` and its tree, ignoring whatever else is in the worktree: what a push would carry.
    public static func committed(worktree: URL, git: GitRunner) async -> ProofIdentity? {
        guard let result = try? await git.run(["rev-parse", "HEAD", "HEAD^{tree}"], in: worktree),
            result.succeeded
        else { return nil }
        let lines = result.stdout.split(separator: "\n").map(String.init)
        guard lines.count == 2 else { return nil }
        return ProofIdentity(commit: lines[0], tree: lines[1])
    }
}

/// Whether a proof still describes the work.
public enum ProofFreshness: String, Sendable, Equatable {
    case current
    /// The work changed after the proof was taken.
    case stale
    /// The log recorded no tree (an older thread) or the current one could not be read.
    case unknown

    public static func of(recordedTree: String?, current: ProofIdentity?) -> ProofFreshness {
        guard let recordedTree, !recordedTree.isEmpty, let current else { return .unknown }
        return recordedTree == current.tree ? .current : .stale
    }
}
