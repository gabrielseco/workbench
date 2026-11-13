import Foundation

/// Where a `fix: update` run branch is checked: its resolution of a merge may not leave a conflict open, and may not change a file
/// that main did not change. Both are facts about the tree, not the agent's word.
enum UpdateGuard {
    /// The files, of those that conflicted, that still hold a conflict marker line. A file that cannot be read counts as unresolved.
    static func unresolved(files: [String], in worktree: URL) -> [String] {
        files.filter { file in
            guard !file.hasPrefix("/"), !file.split(separator: "/").contains(".."),
                let data = try? Data(contentsOf: worktree.appendingPathComponent(file))
            else { return true }
            return hasMarker(String(decoding: data, as: UTF8.self))
        }
    }

    /// A line of `<<<<<<< `, `=======` alone or `>>>>>>> ` at the start: what git writes around a conflict.
    static func hasMarker(_ text: String) -> Bool {
        text.split(separator: "\n", omittingEmptySubsequences: false).contains {
            $0.hasPrefix("<<<<<<< ") || $0.hasPrefix(">>>>>>> ") || $0 == "=======" || $0 == "<<<<<<<" || $0 == ">>>>>>>"
        }
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
