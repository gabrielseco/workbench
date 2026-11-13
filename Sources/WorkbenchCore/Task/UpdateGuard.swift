import Foundation

/// Where a `fix: update` run branch is checked: its resolution of a merge may not leave a conflict open, and may not change a file
/// that main did not change. Both are facts about the tree, not the agent's word.
enum UpdateGuard {
    /// The biggest conflicted file that is read: the agent wrote it, so it is not trusted to be small. A bigger one counts as unresolved.
    static let maxFileBytes = 8 << 20

    /// The files, of those that conflicted, that still hold a conflict marker line. A file that is not a regular file inside the
    /// worktree (a symlink, a FIFO), is too big, or cannot be read counts as unresolved: the agent controls what is there.
    static func unresolved(files: [String], in worktree: URL) -> [String] {
        files.filter { file in
            guard !file.hasPrefix("/"), !file.split(separator: "/").contains(".."),
                let text = readRegularFile(worktree.appendingPathComponent(file))
            else { return true }
            return hasMarker(text)
        }
    }

    /// The file's text, only for a regular file (not followed through a link) up to `maxFileBytes`; nil otherwise.
    static func readRegularFile(_ url: URL) -> String? {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size <= maxFileBytes,
            let handle = try? FileHandle(forReadingFrom: url)
        else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxFileBytes + 1), data.count <= maxFileBytes else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// A line of `<<<<<<< `, `=======` alone or `>>>>>>> ` at the start: what git writes around a conflict.
    static func hasMarker(_ text: String) -> Bool {
        text.split(separator: "\n", omittingEmptySubsequences: false).contains {
            $0.hasPrefix("<<<<<<< ") || $0.hasPrefix(">>>>>>> ") || $0 == "=======" || $0 == "<<<<<<<" || $0 == ">>>>>>>"
        }
    }

    /// Ends the merge `syncBase` left open: the agent's resolution (or none, for a clean merge that stopped before the commit) is staged
    /// and committed as the merge, even when it equals the branch's own tree, which `accept` would not commit. Nil when it is done or
    /// there was no merge, else why not.
    static func concludeMerge(worktree: URL, base: String, git: GitRunner) async -> String? {
        guard let open = try? await git.run(["rev-parse", "-q", "--verify", "MERGE_HEAD"], in: worktree), open.succeeded else {
            return nil
        }
        let message = "chore: bring \(base) into the branch"
        for args in [["add", "-A"], ["commit", "-q", "--no-edit", "-m", message]] {
            guard let done = try? await git.run(args, in: worktree), done.succeeded else {
                return "the merge could not be committed"
            }
        }
        return nil
    }

    /// Nil when everything the update changed relative to the pull request's branch is a file main changed since the branch left it,
    /// else why not. Run on the committed result, before the push.
    static func outsideMain(branch: String, mergeFrom: String, worktree: URL, git: GitRunner) async -> String? {
        let tip = mergeFrom.hasPrefix("origin/") ? mergeFrom : "origin/" + mergeFrom
        async let changed = names(["diff", "--name-only", "-z", "origin/\(branch)", "HEAD"], worktree, git)
        async let base = git.run(["merge-base", "origin/\(branch)", tip], in: worktree)
        guard let mergeBase = try? await base, mergeBase.succeeded else { return "could not tell where the branch left \(tip)" }
        let root = mergeBase.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let mine = await changed, let theirs = await names(["diff", "--name-only", "-z", root, tip], worktree, git) else {
            return "could not list what the update changed"
        }
        // What is pushed must carry the base's history: a merge that did not land would report success without it.
        let ancestor = try? await git.run(["merge-base", "--is-ancestor", tip, "HEAD"], in: worktree)
        guard ancestor?.succeeded == true else {
            return "the branch does not contain \(tip) after the update"
        }
        let extra = Set(mine).subtracting(theirs).sorted()
        guard !extra.isEmpty else { return nil }
        return "the update changed files that \(tip) did not: \(extra.prefix(5).joined(separator: ", "))"
    }

    private static func names(_ args: [String], _ worktree: URL, _ git: GitRunner) async -> [String]? {
        guard let result = try? await git.run(args, in: worktree), result.succeeded, !result.outputTruncated else { return nil }
        return result.stdout.split(separator: "\0").map(String.init)
    }
}

/// What an update run pushes to and merges from, for the step that ships it.
struct UpdateTarget {
    var branch: String
    var mergeFrom: String
}

/// What bringing the base into the branch decided: go on to the turn (with the files that conflict, none for a clean merge), or the
/// run's end.
enum UpdateMerge {
    case go(conflicts: [String])
    case stop(TaskRunResult)
}

extension TaskRunner {
    /// The merge is done here, not asked of the agent: it needs no shell, and what it leaves (markers, or nothing) is what the agent
    /// is told about. A branch that already has the base has nothing to update.
    func bringBaseIn(id: String, from base: String, goal: Goal, service: ThreadService, units: [String]) async -> UpdateMerge {
        do {
            try await service.cutWorktreeIfMissing(id: id, goal: goal)
            switch try await service.syncBase(id: id, from: base) {
            case .upToDate:
                let gone = await discard(id, service: service)
                let note = gone ? "" : "; " + Self.notDiscarded(id)
                let reason = "the branch already has \(base)" + note
                return .stop(TaskRunResult(outcome: .nothingToDo, reason: reason, units: units, thread: id))
            case .merged: return .go(conflicts: [])
            case .conflicts(_, let files, _): return .go(conflicts: files)
            case .failed(_, _, let error):
                return .stop(fail("the merge failed: \(error); thread \(id) is left for you", units: units, thread: id))
            }
        } catch {
            let gone = await discard(id, service: service)
            let note = gone ? "" : "; " + Self.notDiscarded(id)
            return .stop(fail("could not bring \(base) into the branch: \(error)" + note, units: units, thread: id))
        }
    }

    /// Commits the merge the thread has open (see `UpdateGuard.concludeMerge`); the run's end when it cannot.
    func finishMerge(id: String, base: String, units: [String], explanation: TaskExplanation) async -> TaskRunResult? {
        let tree = WorktreeManager(repoRoot: project.root, git: git).path(for: id)
        guard let why = await UpdateGuard.concludeMerge(worktree: tree, base: base, git: git) else { return nil }
        return fail(explanation.reason("\(why); thread \(id) is left for you"), units: units, thread: id)
    }

    /// A conflict the agent did not resolve is the answer "not safe to do unattended", not a failure: nothing is pushed.
    func unresolvedConflicts(
        _ files: [String], id: String, service: ThreadService, units: [String], explanation: TaskExplanation
    ) async -> TaskRunResult? {
        let tree = WorktreeManager(repoRoot: project.root, git: git).path(for: id)
        let left = UpdateGuard.unresolved(files: files, in: tree)
        guard !left.isEmpty else { return nil }
        let gone = await discard(id, service: service)
        let base = "not updated, a person has to merge: conflict left in \(left.joined(separator: ", "))"
        let note = gone ? "" : "; " + Self.notDiscarded(id)
        return TaskRunResult(outcome: .needsYou, reason: explanation.reason(base + note), units: units, thread: id)
    }

    /// Pushes the committed merge to the pull request's own branch, when it changed only what the base changed. Nothing to describe:
    /// the pull request exists.
    func shipUpdate(
        _ update: UpdateTarget, id: String, plan: ShipPlan, service: ThreadService, units: [String], explanation: TaskExplanation
    ) async -> TaskRunResult {
        let stranded = "thread \(id) is accepted but not pushed: workbench ship"
        let outside = await UpdateGuard.outsideMain(
            branch: update.branch, mergeFrom: update.mergeFrom, worktree: plan.worktree, git: git)
        if let outside { return fail(explanation.reason("\(outside); \(stranded)"), units: units, thread: id) }
        do {
            let outcome = try await service.publishShip(
                id: id, gh: gh, plan: plan, description: nil,
                options: ShipPublishOptions(keepWorktree: false, skipScreenshots: true))
            return TaskRunResult(
                outcome: .prOpened, reason: "updated \(update.branch) with \(update.mergeFrom)", units: units, thread: id,
                pullRequest: outcome.pr.url)
        } catch {
            return fail(explanation.reason("\(error); \(stranded)"), units: units, thread: id)
        }
    }
}
