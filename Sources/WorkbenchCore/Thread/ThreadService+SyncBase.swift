import Foundation

/// How far a thread's base has moved on since the thread's branch was cut, and what of it touches the thread's own files.
public struct BaseMovement: Sendable, Equatable {
    /// The goal's base branch, as `origin` knows it.
    public var base: String
    /// The commit `origin/<base>` is at.
    public var tip: String
    /// Commits on `origin/<base>` that the thread's branch does not have.
    public var behind: Int
    /// Files changed both on the base since the branch left it and by the thread (committed or not), sorted, at most `listed`.
    public var overlapping: [String]
    /// There were more overlapping files than `listed`.
    public var overlapTruncated: Bool

    public static let listed = 50

    /// One line for `status` and `review`: how far, and how much of it is the thread's ground.
    public var line: String {
        guard behind > 0 else { return "\(base) has not moved since this thread started" }
        let commits = behind == 1 ? "1 commit" : "\(behind) commits"
        guard !overlapping.isEmpty else { return "\(base) moved by \(commits); none touch files this thread changed" }
        let shown = overlapping.prefix(3).joined(separator: ", ")
        let more = overlapping.count > 3 || overlapTruncated ? ", ..." : ""
        let count = overlapTruncated ? "\(overlapping.count)+" : "\(overlapping.count)"
        return "\(base) moved by \(commits); \(count) file(s) it changed were touched there too: \(shown)\(more)"
    }
}

/// What `syncBase` did.
public enum BaseSyncResult: Sendable, Equatable {
    /// The base had not moved: nothing was changed.
    case upToDate(BaseMovement)
    /// The base was merged into the thread's branch without a conflict. `savedWork` is the commit that kept the thread's
    /// uncommitted work out of the merge's way, nil when there was none.
    case merged(BaseMovement, head: String, savedWork: String?)
    /// The merge stopped on these files, which hold conflict markers in the worktree; the merge is left in progress.
    case conflicts(BaseMovement, files: [String], savedWork: String?)
    /// Git could not merge and there was no conflict to resolve; only recorded, never returned (the sync throws `syncFailed`).
    case failed(BaseMovement, saved: String?, error: String)
}

extension ThreadService {
    /// The base branch a thread's goal names, as a name on `origin`: `origin/main` and `main` both mean `main`.
    static func originBranch(ofBase base: String) -> String {
        base.hasPrefix("origin/") ? String(base.dropFirst("origin/".count)) : base
    }

    private func baseOf(_ id: String) throws -> String {
        guard let text = try? String(contentsOf: project.goalURL(id), encoding: .utf8),
            let goal = try? GoalFile.parse(text).goal
        else { throw ThreadServiceError.goalMissing(project.goalURL(id).path) }
        let branch = Self.originBranch(ofBase: goal.base)
        guard SafeNames.isBranchName(branch) else { throw ThreadStoreError.invalidName(goal.base) }
        return branch
    }

    /// How far `origin/<base>` is ahead of the thread's branch, and which of the thread's files it also touched. Nil when the
    /// thread has no worktree or origin has no such branch. With `fetch`, one bounded fetch first and a failure throws (a
    /// stale answer must not be passed off as fresh); without it nothing touches the network and the answer is as old as the
    /// last fetch.
    public func baseMovement(id: String, fetch: Bool) async throws -> BaseMovement? {
        guard SafeNames.isThreadID(id) else { throw ThreadStoreError.invalidName(id) }
        let manager = WorktreeManager(repoRoot: project.root, git: git)
        guard manager.exists(id) else { return nil }
        let base = try baseOf(id)
        let worktree = manager.path(for: id)

        var tip: String
        if fetch {
            do { tip = try await manager.fetchRemoteBranch(base) } catch {
                throw ThreadServiceError.syncFailed("\(error)")
            }
        } else {
            let known = try await git.run(
                ["rev-parse", "--verify", "--quiet", "refs/remotes/origin/\(base)^{commit}"], in: project.root)
            guard known.succeeded else { return nil }
            tip = known.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let mergeBase = try await git.run(["merge-base", "HEAD", tip], in: worktree)
        guard mergeBase.succeeded else {
            throw ThreadServiceError.syncFailed("the thread's branch and origin/\(base) share no history")
        }
        let root = mergeBase.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let count = try await git.run(["rev-list", "--count", "HEAD..\(tip)"], in: worktree)
        let behind = Int(count.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        guard behind > 0 else {
            return BaseMovement(base: base, tip: tip, behind: 0, overlapping: [], overlapTruncated: false)
        }

        // Theirs: what the base changed since the branch left it. Ours: the working tree against that same point, so
        // committed work and work not yet committed both count, and so do new files.
        let theirs = Set(try await lines(["diff", "--name-only", "-z", root, tip], in: worktree, separator: "\0"))
        var ours = Set(try await lines(["diff", "--name-only", "-z", root], in: worktree, separator: "\0"))
        ours.formUnion(
            try await lines(["ls-files", "--others", "--exclude-standard", "-z"], in: worktree, separator: "\0"))
        let both = theirs.intersection(ours).sorted()
        return BaseMovement(
            base: base, tip: tip, behind: behind, overlapping: Array(both.prefix(BaseMovement.listed)),
            overlapTruncated: both.count > BaseMovement.listed)
    }

    private func lines(_ arguments: [String], in directory: URL, separator: Character) async throws -> [String] {
        let result = try await git.run(arguments, in: directory)
        guard result.succeeded else {
            throw ThreadServiceError.syncFailed("git \(arguments.prefix(2).joined(separator: " ")) failed: \(result.stderr)")
        }
        return result.stdout.split(separator: separator).map(String.init)
    }

    /// Brings the base's new commits into the thread's branch, in its worktree: fetch `origin/<base>`, keep any uncommitted work
    /// in a commit of its own, then merge. A clean merge is committed; a conflict leaves the merge in progress with the markers
    /// in the files, for a person or a `send-back` turn to resolve. History is never rewritten, so a branch that was pushed
    /// needs no force-push. Records `base.synced`. The thread's log is held from the first check to the record, so a run cannot
    /// start on the worktree in between.
    public func syncBase(id: String) async throws -> BaseSyncResult {
        guard SafeNames.isThreadID(id) else { throw ThreadStoreError.invalidName(id) }
        do {
            return try await withLog(id) { log in try await self.sync(id: id, log: log) }
        } catch EventLogError.alreadyOpen {
            throw ThreadServiceError.syncRefused(
                "a run holds this thread (pid \(runnerPID(id: id).map(String.init) ?? "?")): `workbench stop` it first")
        }
    }

    private func sync(id: String, log: EventLogWriter) async throws -> BaseSyncResult {
        if let decision = ThreadStore(project: project).state(of: id).decision { throw ThreadServiceError.threadEnded(decision) }
        if let pid = runnerPID(id: id) { throw ThreadServiceError.running(pid: pid) }
        let manager = WorktreeManager(repoRoot: project.root, git: git)
        guard manager.exists(id) else {
            throw ThreadServiceError.syncRefused("this thread has no worktree yet, so it has not started from any base")
        }
        let worktree = manager.path(for: id)
        // The branch is the thread's own: work saved and merged on another one would not be the thread's.
        let onBranch = try await git.run(["symbolic-ref", "--short", "-q", "HEAD"], in: worktree)
        let found = onBranch.succeeded ? onBranch.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        guard found == WorktreeManager.branch(for: id) else {
            throw ThreadServiceError.syncRefused(
                "the worktree is on '\(found.isEmpty ? "a detached HEAD" : found)', not \(WorktreeManager.branch(for: id)): "
                    + "switch it back first")
        }
        let inProgress = try await git.run(["rev-parse", "-q", "--verify", "MERGE_HEAD"], in: worktree)
        guard !inProgress.succeeded else {
            throw ThreadServiceError.syncRefused(
                "a merge is already in progress in \(worktree.path): resolve it (or `git merge --abort` there), then try again")
        }

        guard let movement = try await baseMovement(id: id, fetch: true) else {
            throw ThreadServiceError.syncRefused("origin has no branch '\(try baseOf(id))' to bring in")
        }
        guard movement.behind > 0 else { return .upToDate(movement) }

        // Work that is not committed yet would be in the merge's way, or be mixed into its conflicts: it gets a commit.
        var saved: String?
        let pending = try await Self.pendingChanges(in: worktree, git: git)
        if !pending.isEmpty {
            let added = try await git.run(["add", "-A"], in: worktree)
            let message = "chore: save work before bringing \(movement.base) in"
            let committed = added.succeeded ? try await git.run(["commit", "-q", "-m", message], in: worktree) : added
            guard committed.succeeded else {
                let why = (committed.stderr + committed.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
                throw ThreadServiceError.syncFailed(
                    "the thread's uncommitted work could not be committed, so nothing was merged (its changes are staged "
                        + "in the worktree): \(why)")
            }
            saved = try await shortHead(worktree)
        }

        let message = "chore: bring \(movement.base) into \(WorktreeManager.branch(for: id))"
        let merge = try await git.run(["merge", "--no-edit", "-m", message, movement.tip], in: worktree)
        let result: BaseSyncResult
        if merge.succeeded {
            result = .merged(movement, head: try await shortHead(worktree), savedWork: saved)
        } else {
            let unmerged = try await lines(["diff", "--name-only", "--diff-filter=U", "-z"], in: worktree, separator: "\0")
            guard !unmerged.isEmpty else {
                let why = (merge.stderr + merge.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
                let open = try await git.run(["rev-parse", "-q", "--verify", "MERGE_HEAD"], in: worktree).succeeded
                let state = open ? "the merge is left in progress in \(worktree.path)" : "nothing was merged"
                try await record(.failed(movement, saved: saved, error: why), log: log)
                throw ThreadServiceError.syncFailed("git could not merge origin/\(movement.base) (\(state)): \(why)")
            }
            result = .conflicts(movement, files: unmerged.sorted(), savedWork: saved)
        }
        try await record(result, log: log)
        return result
    }

    private func shortHead(_ worktree: URL) async throws -> String {
        let head = try await git.run(["rev-parse", "--short=12", "HEAD"], in: worktree)
        return head.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func record(_ result: BaseSyncResult, log: EventLogWriter) async throws {
        var data: [String: JSONValue] = [:]
        let movement: BaseMovement
        switch result {
        case .upToDate: return
        case .merged(let moved, let head, let saved):
            movement = moved
            data["result"] = "merged"
            data["head"] = .string(head)
            if let saved { data["saved_work"] = .string(saved) }
        case .conflicts(let moved, let files, let saved):
            movement = moved
            data["result"] = "conflicts"
            data["conflicts"] = .array(files.map { .string($0) })
            if let saved { data["saved_work"] = .string(saved) }
        case .failed(let moved, let saved, let error):
            movement = moved
            data["result"] = "failed"
            data["error"] = .string(String(error.prefix(500)))
            if let saved { data["saved_work"] = .string(saved) }
        }
        data["base"] = .string(movement.base)
        data["tip"] = .string(String(movement.tip.prefix(12)))
        data["behind"] = .int(movement.behind)
        data["overlapping"] = .array(movement.overlapping.map { .string($0) })
        _ = try await log.append(.baseSynced, data: .object(data))
    }
}
