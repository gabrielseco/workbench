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
    ///
    /// `git add` runs a clean filter for a file its attributes name, and the model can write `.gitattributes`
    /// (or commit it) in the worktree. So the attributes are read from `attributesFrom`, the commit the thread was
    /// cut from, and from an empty tree when that is not known: nothing the run wrote can choose a filter. A filter
    /// the base commit selects still runs, as it does for `accept` and for the diff `review` already takes of the
    /// worktree; if its command is a script inside the repository the run can edit it, which no attribute choice
    /// here can prevent.
    public static func of(worktree: URL, git: GitRunner, attributesFrom base: String?) async -> ProofIdentity? {
        let index = FileManager.default.temporaryDirectory.appendingPathComponent("wb-index-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: index) }
        var environment = git.environment
        environment["GIT_INDEX_FILE"] = index.path
        guard let source = await attributeSource(base, worktree: worktree, git: git) else { return nil }
        environment["GIT_ATTR_SOURCE"] = source
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
    /// Where attributes are read from: `base` when it names a commit, else the repository's empty tree. Nil only
    /// when even that cannot be found, in which case the caller must not compute a tree.
    private static func attributeSource(_ base: String?, worktree: URL, git: GitRunner) async -> String? {
        if let base, SafeNames.isCommitSHA(base) { return base }
        guard let empty = try? await git.run(["hash-object", "-t", "tree", "--stdin"], in: worktree), empty.succeeded
        else { return nil }
        let id = empty.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? nil : id
    }
}

extension ProofIdentity {
    /// `HEAD` and its tree, ignoring whatever else is in the worktree: what a push would carry.
    public static func committed(worktree: URL, git: GitRunner) async -> ProofIdentity? {
        await committed(ref: "HEAD", in: worktree, git: git)
    }

    /// A commit (a branch tip) and its tree, for a thread whose worktree is gone. `ref` is a commit id or `HEAD`.
    public static func committed(ref: String, in directory: URL, git: GitRunner) async -> ProofIdentity? {
        guard ref == "HEAD" || SafeNames.isCommitSHA(ref),
            let result = try? await git.run(["rev-parse", ref, "\(ref)^{tree}"], in: directory), result.succeeded
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
