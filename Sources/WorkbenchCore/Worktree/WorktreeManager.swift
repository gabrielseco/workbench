import Foundation

public struct Worktree: Sendable, Equatable {
    public var threadID: String
    public var path: URL
    public var branch: String
    /// The commit `base` pointed at when the worktree was cut.
    public var baseCommit: String
}

public enum WorktreeError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidThreadID(String)
    case invalidBase(String)
    case notAGitRepository(String)
    case baseNotFound(String)
    /// Tracked files in the main checkout have uncommitted changes.
    case dirtyRepository([String])
    case worktreeExists(String)
    case branchExists(String)
    case worktreeNotFound(String)
    case gitFailed(command: String, status: Int32, stderr: String)

    public var description: String {
        switch self {
        case .invalidThreadID(let id): "'\(id)' is not a valid thread id"
        case .invalidBase(let base): "'\(base)' is not a safe branch name"
        case .notAGitRepository(let path): "\(path) is not a git repository"
        case .baseNotFound(let base): "base '\(base)' does not resolve to a commit"
        case .dirtyRepository(let files):
            "the repository has uncommitted changes: \(files.prefix(5).joined(separator: ", "))"
                + (files.count > 5 ? " and \(files.count - 5) more" : "")
        case .worktreeExists(let path): "a worktree already exists at \(path)"
        case .branchExists(let name): "branch '\(name)' already exists"
        case .worktreeNotFound(let path): "no worktree at \(path)"
        case .gitFailed(let command, let status, let stderr):
            "git \(command) failed (exit \(status)): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
    }
}

/// Creates and removes the git worktree a thread works in: `<repo>/.workbench/worktrees/<id>` on branch
/// `workbench/<id>`, cut from a fixed commit of `base`.
public struct WorktreeManager: Sendable {
    public static let branchPrefix = "workbench/"

    public let repoRoot: URL
    private let git: GitRunner

    public init(repoRoot: URL, git: GitRunner) {
        self.repoRoot = repoRoot.resolvingSymlinksInPath()
        self.git = git
    }

    public func path(for threadID: String) -> URL {
        repoRoot.appendingPathComponent(".workbench/worktrees/\(threadID)")
    }

    public static func branch(for threadID: String) -> String { branchPrefix + threadID }

    public func exists(_ threadID: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path(for: threadID).path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    // MARK: Create

    /// - Parameter allowDirty: skip the clean-checkout check. The worktree is cut from the committed
    ///   `base` either way; the check exists because accepting the work later merges into this checkout.
    /// - Parameter commit: the commit recorded for `base` when the thread was created. The worktree is cut
    ///   from it, so the thread has one base commit even if `base` has moved since.
    public func create(
        threadID: String, base: String, commit: String? = nil, allowDirty: Bool = false
    ) async throws -> Worktree {
        guard SafeNames.isThreadID(threadID) else { throw WorktreeError.invalidThreadID(threadID) }
        guard SafeNames.isBranchName(base) else { throw WorktreeError.invalidBase(base) }

        try await requireRepository()
        if !allowDirty {
            let dirty = try await trackedChanges()
            if !dirty.isEmpty { throw WorktreeError.dirtyRepository(dirty) }
        }

        let baseCommit = try await resolveCommit(commit.flatMap { SafeNames.isCommitID($0) ? $0 : nil } ?? base)
        let target = path(for: threadID)
        let branch = Self.branch(for: threadID)

        // A worktree directory deleted by hand leaves a stale registration that blocks `add`.
        _ = try await git.run(["worktree", "prune"], in: repoRoot)

        if FileManager.default.fileExists(atPath: target.path) {
            throw WorktreeError.worktreeExists(target.path)
        }
        let branchProbe = try await git.run(
            ["show-ref", "--verify", "--quiet", "refs/heads/\(branch)"], in: repoRoot)
        if branchProbe.succeeded { throw WorktreeError.branchExists(branch) }

        try await keepWorkbenchOutOfStatus()
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)

        try await check(["worktree", "add", "--no-track", "-b", branch, target.path, baseCommit])
        return Worktree(threadID: threadID, path: target, branch: branch, baseCommit: baseCommit)
    }

    // MARK: Remove

    /// Removes the worktree directory. Git refuses when it has uncommitted changes unless `force`.
    /// The branch (and any commits on it) is kept unless `deleteBranch`.
    public func remove(threadID: String, force: Bool = false, deleteBranch: Bool = false) async throws {
        guard SafeNames.isThreadID(threadID) else { throw WorktreeError.invalidThreadID(threadID) }
        try await requireRepository()
        let target = path(for: threadID)
        guard exists(threadID) else { throw WorktreeError.worktreeNotFound(target.path) }

        var args = ["worktree", "remove"]
        if force { args.append("--force") }
        args.append(target.path)
        try await check(args)

        if deleteBranch {
            try await check(["branch", "-D", Self.branch(for: threadID)])
        }
    }

    // MARK: Inspection

    /// The commit `base` points at now, if it is a safe name that resolves.
    public func commit(of base: String) async -> String? {
        guard SafeNames.isBranchName(base) else { return nil }
        return try? await resolveCommit(base)
    }

    /// Where a thread's branch left `base`: the base commit of a thread whose log does not record one.
    public func forkPoint(of threadID: String, base: String) async -> String? {
        guard SafeNames.isThreadID(threadID), SafeNames.isBranchName(base),
            let result = try? await git.run(["merge-base", Self.branch(for: threadID), base], in: repoRoot),
            result.succeeded
        else { return nil }
        let sha = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return SafeNames.isCommitID(sha) ? sha : nil
    }

    /// Uncommitted changes inside a thread's worktree (tracked and untracked), as porcelain lines.
    public func changes(in threadID: String) async throws -> [String] {
        guard exists(threadID) else { throw WorktreeError.worktreeNotFound(path(for: threadID).path) }
        let result = try await git.run(["status", "--porcelain"], in: path(for: threadID))
        guard result.succeeded else {
            throw WorktreeError.gitFailed(command: "status", status: result.status, stderr: result.stderr)
        }
        return Self.lines(result.stdout)
    }

    // MARK: Internals

    private func requireRepository() async throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: repoRoot.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else { throw WorktreeError.notAGitRepository(repoRoot.path) }

        let result = try await git.run(["rev-parse", "--show-toplevel"], in: repoRoot)
        guard result.succeeded else { throw WorktreeError.notAGitRepository(repoRoot.path) }
        let top = URL(fileURLWithPath: result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
            .resolvingSymlinksInPath()
        // Running from a subdirectory would put worktrees in the wrong place.
        guard top.path == repoRoot.path else { throw WorktreeError.notAGitRepository(repoRoot.path) }
    }

    private func trackedChanges() async throws -> [String] {
        let result = try await git.run(
            ["status", "--porcelain", "--untracked-files=no", "--", ".", ":(exclude).workbench"],
            in: repoRoot)
        guard result.succeeded else {
            throw WorktreeError.gitFailed(command: "status", status: result.status, stderr: result.stderr)
        }
        return Self.lines(result.stdout)
    }

    private func resolveCommit(_ base: String) async throws -> String {
        let result = try await git.run(
            ["rev-parse", "--verify", "--quiet", "\(base)^{commit}"], in: repoRoot)
        let sha = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.succeeded, !sha.isEmpty else { throw WorktreeError.baseNotFound(base) }
        return sha
    }

    /// `.workbench/` lives inside the repo but is ours, so keep it out of `git status` without editing
    /// the project's tracked `.gitignore`. `info/exclude` is local to this clone.
    private func keepWorkbenchOutOfStatus() async throws {
        let result = try await git.run(
            ["rev-parse", "--path-format=absolute", "--git-common-dir"], in: repoRoot)
        guard result.succeeded else {
            throw WorktreeError.gitFailed(command: "rev-parse", status: result.status, stderr: result.stderr)
        }
        let commonDir = URL(fileURLWithPath: result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        let exclude = commonDir.appendingPathComponent("info/exclude")
        let entry = ".workbench/"

        let existing = (try? String(contentsOf: exclude, encoding: .utf8)) ?? ""
        if existing.split(separator: "\n").contains(where: { $0.trimmingCharacters(in: .whitespaces) == entry }) {
            return
        }
        try FileManager.default.createDirectory(
            at: exclude.deletingLastPathComponent(), withIntermediateDirectories: true)
        let separator = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
        try (existing + separator + entry + "\n").write(to: exclude, atomically: true, encoding: .utf8)
    }

    private func check(_ args: [String]) async throws {
        let result = try await git.run(args, in: repoRoot)
        guard result.succeeded else {
            throw WorktreeError.gitFailed(
                command: args.prefix(2).joined(separator: " "), status: result.status, stderr: result.stderr)
        }
    }

    private static func lines(_ text: String) -> [String] {
        text.split(separator: "\n").map(String.init)
    }
}
