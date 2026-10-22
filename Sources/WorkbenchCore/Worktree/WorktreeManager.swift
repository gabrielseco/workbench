import Foundation

public struct Worktree: Sendable, Equatable {
    public var threadID: String
    public var path: URL
    public var branch: String
    /// The commit `base` pointed at when the worktree was cut.
    public var baseCommit: String
    /// What the project's `copy` patterns put in from the main checkout.
    public var copy = CopyReport()

    /// The `worktree.created` payload.
    var eventData: JSONValue {
        var fields: [String: JSONValue] = [
            "path": .string(path.path), "branch": .string(branch), "base_commit": .string(baseCommit),
        ]
        if !copy.copied.isEmpty { fields["copied"] = .array(copy.copied.map { .string($0) }) }
        return .object(fields)
    }
}

public enum WorktreeError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidThreadID(String)
    case invalidBase(String)
    case notAGitRepository(String)
    case baseNotFound(String)
    case worktreeExists(String)
    case branchExists(String)
    case worktreeNotFound(String)
    case gitFailed(command: String, status: Int32, stderr: String)
    case remoteBranchUnavailable(branch: String, reason: String)

    public var description: String {
        switch self {
        case .invalidThreadID(let id): "'\(id)' is not a valid thread id"
        case .invalidBase(let base): "'\(base)' is not a safe branch name"
        case .notAGitRepository(let path): "\(path) is not a git repository"
        case .baseNotFound(let base): "base '\(base)' does not resolve to a commit"
        case .worktreeExists(let path): "a worktree already exists at \(path)"
        case .branchExists(let name): "branch '\(name)' already exists"
        case .worktreeNotFound(let path): "no worktree at \(path)"
        case .remoteBranchUnavailable(let branch, let reason):
            "cannot read origin/\(branch): \(reason)"
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

    /// The worktree is cut from the committed `base`, so uncommitted edits in this checkout never reach it
    /// and no clean checkout is needed (accept commits on the thread's branch and merges nothing here).
    public func create(
        threadID: String, base: String, fetching remoteBranch: String? = nil, copying patterns: [String] = []
    ) async throws -> Worktree {
        guard SafeNames.isThreadID(threadID) else { throw WorktreeError.invalidThreadID(threadID) }
        guard SafeNames.isBranchName(base) else { throw WorktreeError.invalidBase(base) }

        try await requireRepository()
        // The fetched commit is used as is: `origin/<branch>` by name could resolve to a local branch or tag.
        var fetched: String?
        if let remoteBranch { fetched = try await fetchRemoteBranch(remoteBranch) }

        let baseCommit: String
        if let fetched { baseCommit = fetched } else { baseCommit = try await resolveCommit(base) }
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

        try await excludeWorkbench()
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)

        try await check(["worktree", "add", "--no-track", "-b", branch, target.path, baseCommit])
        let copy = await WorktreeCopier(source: repoRoot, git: git).copy(patterns, to: target)
        return Worktree(threadID: threadID, path: target, branch: branch, baseCommit: baseCommit, copy: copy)
    }

    /// Finishes a copy a killed run left half done: what is already in the worktree is kept, the rest is copied.
    public func copyMissing(_ patterns: [String], into threadID: String) async -> CopyReport {
        guard SafeNames.isThreadID(threadID), exists(threadID), !patterns.isEmpty else { return CopyReport() }
        return await WorktreeCopier(source: repoRoot, git: git).copy(patterns, to: path(for: threadID))
    }

    // MARK: Goal copy

    /// Where the goal is shown inside a worktree. The folder name is Workbench's own, so nothing in a project is at
    /// this path, and `.workbench/` is already kept out of git (`excludeWorkbench`): `git add -A` in a run, `accept`
    /// and `ship` never take it, and the worktree's removal takes it with it.
    public static let goalCopyPath = ".workbench/goal-copy/goal.md"

    public enum GoalCopy: Sendable, Equatable {
        case written
        /// Nothing was written, and why, for the person who opens the worktree and finds no goal.
        case skipped(String)
    }

    /// Puts a read-only copy of the approved goal in the thread's worktree, so an editor opened on it shows the goal
    /// beside the diff. The source stays in the thread's folder: the copy is replaced on every turn and editing it
    /// changes nothing the approval covers.
    ///
    /// It only ever replaces that one file. It writes nothing when `.workbench`, `goal-copy` or the file is something
    /// else (a link, a file where a folder belongs, a folder where the file belongs), when the file is tracked, or when
    /// git would not ignore the path (a file git sees could be committed); in that last case it removes its own earlier
    /// copy, and nothing else.
    public func writeGoalCopy(_ text: String, for threadID: String) async -> GoalCopy {
        guard SafeNames.isThreadID(threadID), exists(threadID) else { return .skipped("the thread has no worktree") }
        let worktree = path(for: threadID)
        let copy = worktree.appendingPathComponent(Self.goalCopyPath)
        let folder = copy.deletingLastPathComponent()
        let parent = folder.deletingLastPathComponent()
        for dir in [parent, folder] {
            if let type = Self.type(of: dir), type != .typeDirectory {
                return .skipped("\(dir.lastPathComponent) in the worktree is not a plain folder")
            }
        }
        if let type = Self.type(of: copy), type != .typeRegular {
            return .skipped("\(Self.goalCopyPath) is not a plain file")
        }
        let tracked = try? await git.run(["ls-files", "--error-unmatch", "--", Self.goalCopyPath], in: worktree)
        if tracked?.succeeded == true { return .skipped("\(Self.goalCopyPath) is tracked by the project") }
        let ignored = try? await git.run(["check-ignore", "-q", Self.goalCopyPath], in: worktree)
        guard ignored?.succeeded == true else {
            // The ignore rules changed since an earlier turn: a copy left in place would be committed by `git add -A`.
            if Self.type(of: copy) == .typeRegular {
                try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: copy.path)
                try? FileManager.default.removeItem(at: copy)
            }
            return .skipped("git would not ignore \(Self.goalCopyPath)")
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if Self.type(of: copy) == .typeRegular {
                try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: copy.path)
            }
            try text.write(to: copy, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: copy.path)
            return .written
        } catch {
            return .skipped("\(error.localizedDescription)")
        }
    }

    /// What is at `url`, without following a link; nil when nothing is.
    private static func type(of url: URL) -> FileAttributeType? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
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

    /// `false` only when git says the ref is missing (exit 1); any other failure is thrown, so "could not
    /// look" is never taken for "not there".
    public func branchExists(_ threadID: String) async throws -> Bool {
        guard SafeNames.isThreadID(threadID) else { throw WorktreeError.invalidThreadID(threadID) }
        let ref = "refs/heads/" + Self.branch(for: threadID)
        let result = try await git.run(["rev-parse", "--verify", "--quiet", ref], in: repoRoot)
        if result.succeeded { return true }
        if result.status == 1 { return false }
        throw WorktreeError.gitFailed(command: "rev-parse", status: result.status, stderr: result.stderr)
    }

    /// Deletes `workbench/<id>` and nothing else: the name is built here from a checked thread id.
    public func deleteBranch(threadID: String) async throws {
        guard SafeNames.isThreadID(threadID) else { throw WorktreeError.invalidThreadID(threadID) }
        try await requireRepository()
        try await check(["branch", "-D", Self.branch(for: threadID)])
    }

    /// Up to eleven commits not on `base`, newest first; nil means inspection failed, not an empty history.
    public func commits(threadID: String, since base: String) async -> [String]? {
        guard SafeNames.isThreadID(threadID), SafeNames.isBranchName(base) || base.range(
            of: "^[0-9a-f]{7,64}$", options: .regularExpression) != nil
        else { return nil }
        let result = try? await git.run(
            ["log", "--max-count=11", "--oneline", "--no-decorate", "\(base)..refs/heads/\(Self.branch(for: threadID))"],
            in: repoRoot)
        guard let result, result.succeeded, result.stdout.utf8.count < GitRunner.outputLimit else { return nil }
        return Self.lines(result.stdout)
    }

    // MARK: Inspection

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

    /// Uncommitted changes to tracked files in the main checkout, which a thread does not contain.
    public func checkoutChanges() async throws -> [String] {
        let result = try await git.run(
            ["status", "--porcelain", "--untracked-files=no", "--", ".", ":(exclude).workbench"],
            in: repoRoot)
        guard result.succeeded else {
            throw WorktreeError.gitFailed(command: "status", status: result.status, stderr: result.stderr)
        }
        return Self.lines(result.stdout)
    }

    /// A throwaway, detached checkout of `commit` at `target`, for a read-only turn. It has no branch, so removing it
    /// leaves nothing behind in the repository but git's own bookkeeping, which `worktree prune` clears.
    public func addDetached(at target: URL, commit: String) async throws {
        try await requireRepository()
        _ = try await git.run(["worktree", "prune"], in: repoRoot)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await check(["worktree", "add", "--detach", target.path, commit])
    }

    /// Removes a checkout `addDetached` made, whatever state it was left in: through git first, then by hand.
    /// Returns whether it is gone, so a caller never takes a failed removal for a clean one.
    @discardableResult
    public func removeDetached(at target: URL) async -> Bool {
        _ = try? await git.run(["worktree", "remove", "--force", target.path], in: repoRoot)
        try? FileManager.default.removeItem(at: target)
        _ = try? await git.run(["worktree", "prune"], in: repoRoot)
        return !FileManager.default.fileExists(atPath: target.path)
    }

    /// The commit a branch name or sha names, for a plan made before any worktree exists.
    public func commit(of base: String) async throws -> String {
        guard SafeNames.isBranchName(base) else { throw WorktreeError.invalidBase(base) }
        return try await resolveCommit(base)
    }

    private func resolveCommit(_ base: String) async throws -> String {
        let result = try await git.run(
            ["rev-parse", "--verify", "--quiet", "\(base)^{commit}"], in: repoRoot)
        let sha = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.succeeded, !sha.isEmpty else { throw WorktreeError.baseNotFound(base) }
        return sha
    }

    /// `.workbench/` lives inside the repo but is ours, so keep it out of `git status` without editing
    /// the project's tracked `.gitignore`. `info/exclude` is local to this clone. Does nothing when the
    /// repository already ignores it.
    public func excludeWorkbench() async throws {
        let ignored = try await git.run(["check-ignore", "-q", ".workbench/"], in: repoRoot)
        if ignored.succeeded { return }
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

    // MARK: Base against origin

    public struct BaseGap: Sendable, Equatable {
        public var base: String
        /// Commits on `origin/<base>` that the local branch does not have.
        public var behind: Int
        /// Why the fetch did not happen, when it did not; the comparison then uses what is already known.
        public var fetchNote: String?
    }

    /// How far the local `base` branch is behind `origin/<base>`, after one bounded fetch of that branch.
    /// nil when there is no `origin`, `base` is not a local branch, or origin has no such branch. A fetch
    /// that fails is a note, never an error: being offline must not stop work.
    public func baseGap(base: String, fetchTimeout: TimeInterval = 20) async -> BaseGap? {
        guard SafeNames.isBranchName(base) else { return nil }
        guard let origin = try? await git.run(["remote", "get-url", "origin"], in: repoRoot), origin.succeeded
        else { return nil }
        let local = try? await git.run(["rev-parse", "--verify", "--quiet", "refs/heads/\(base)"], in: repoRoot)
        guard local?.succeeded == true else { return nil }

        var note: String?
        let fetcher = GitRunner(executable: git.executable, environment: git.environment, timeout: fetchTimeout)
        let refspec = "+refs/heads/\(base):refs/remotes/origin/\(base)"
        do {
            let fetched = try await fetcher.run(["fetch", "--no-tags", "--quiet", "origin", refspec], in: repoRoot)
            if !fetched.succeeded {
                let first = fetched.stderr.split(separator: "\n").first.map(String.init) ?? "exit \(fetched.status)"
                note = "could not fetch origin (\(ThreadService.withoutCredentials(first)))"
            }
        } catch GitError.timedOut {
            note = "could not fetch origin (no answer in \(Int(fetchTimeout))s)"
        } catch {
            note = "could not fetch origin"
        }
        let remote = "refs/remotes/origin/\(base)"
        let known = try? await git.run(["rev-parse", "--verify", "--quiet", remote], in: repoRoot)
        guard known?.succeeded == true else { return note == nil ? nil : BaseGap(base: base, behind: 0, fetchNote: note) }
        let count = try? await git.run(["rev-list", "--count", "refs/heads/\(base)..\(remote)"], in: repoRoot)
        let behind = Int(count?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
        return BaseGap(base: base, behind: behind, fetchNote: note)
    }

    /// Brings `refs/remotes/origin/<branch>` up to date and returns its commit. Unlike `baseGap`, a failure
    /// throws: a thread that continues a branch must start from that branch's real tip, never a stale one.
    @discardableResult
    public func fetchRemoteBranch(_ branch: String, timeout: TimeInterval = 30) async throws -> String {
        guard SafeNames.isBranchName(branch) else { throw WorktreeError.invalidBase(branch) }
        guard let origin = try? await git.run(["remote", "get-url", "origin"], in: repoRoot), origin.succeeded
        else { throw WorktreeError.remoteBranchUnavailable(branch: branch, reason: "this repository has no origin") }

        let fetcher = GitRunner(executable: git.executable, environment: git.environment, timeout: timeout)
        let refspec = "+refs/heads/\(branch):refs/remotes/origin/\(branch)"
        do {
            let fetched = try await fetcher.run(["fetch", "--no-tags", "--quiet", "origin", refspec], in: repoRoot)
            guard fetched.succeeded else {
                let first = fetched.stderr.split(separator: "\n").first.map(String.init) ?? "exit \(fetched.status)"
                throw WorktreeError.remoteBranchUnavailable(
                    branch: branch, reason: ThreadService.withoutCredentials(first))
            }
        } catch GitError.timedOut {
            throw WorktreeError.remoteBranchUnavailable(branch: branch, reason: "no answer in \(Int(timeout))s")
        }
        return try await resolveCommit("refs/remotes/origin/\(branch)")
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
