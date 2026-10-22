import Foundation

public enum ShipCleanup: Sendable, Equatable {
    case removed(path: String)
    /// Nothing was removed, and why. The thread is shipped either way.
    case kept(String)
    case alreadyGone
    case notShipped
}

extension ThreadService {
    /// Removes a shipped thread's worktree when nothing could be lost: it is on `workbench/<id>`, clean
    /// (nothing uncommitted), at the commit `pr.opened` recorded, that commit is what `origin` has, and no
    /// run is active. Never forces. The branch is kept. Records `worktree.removed` and nothing else.
    ///
    /// "Clean" means no change git would report: an ignored file does not keep it, since a worktree Workbench made
    /// holds only what its setup, check, verify step or run produced. The event names what was ignored in it.
    ///
    /// `requireOrigin: false` is for a pull request that is already merged or closed: origin has usually
    /// dropped the branch by then, and the caller has checked the PR's head is the shipped commit.
    ///
    /// `dryRun` answers the same questions without touching anything: it returns `.removed` for a worktree
    /// that would go, and neither sweeps, prunes, records nor removes.
    public func cleanShipped(
        id: String, gh: GitRunner?, requireOrigin: Bool = true, dryRun: Bool = false
    ) async -> ShipCleanup {
        guard SafeNames.isThreadID(id) else { return .kept("'\(id)' is not a thread id") }
        let events = (try? EventLogReader.read(at: project.eventsURL(id)))?.events ?? []
        guard let opened = events.last(where: { $0.kind == .prOpened }),
            let head = opened.data["head_sha"]?.stringValue,
            head.range(of: "^[0-9a-f]{40,64}$", options: .regularExpression) != nil
        else { return .notShipped }

        let manager = WorktreeManager(repoRoot: project.root, git: git)
        let removedRecorded = events.contains { $0.kind == .worktreeRemoved }
        guard manager.exists(id) else {
            // Gone without a record (the process died between removing and writing): say it now.
            // A directory deleted by hand can leave git's registration behind: prune it before claiming done.
            if dryRun { return removedRecorded ? .alreadyGone : .removed(path: manager.path(for: id).path) }
            _ = try? await git.run(["worktree", "prune"], in: project.root)
            let listed = try? await git.run(["worktree", "list", "--porcelain"], in: project.root)
            let target = manager.path(for: id).path
            if listed?.stdout.split(separator: "\n").contains(where: { $0 == "worktree \(target)" }) == true {
                return .kept("git still lists the worktree at \(target); `git worktree prune` did not clear it")
            }
            guard !removedRecorded else { return .alreadyGone }
            do { try await recordRemoval(id: id, head: head, swept: []) } catch {
                return .kept("the worktree is gone but the log could not be written: \(error)")
            }
            return .alreadyGone
        }
        let worktree = manager.path(for: id)
        let branch = WorktreeManager.branch(for: id)
        if let pid = runnerPID(id: id) { return .kept("a run is still active (pid \(pid))") }

        // Children a dead runner left could write into the worktree while it is inspected: stop them first,
        // then look, and look again right before removing.
        let swept = dryRun ? [] : OrphanSweeper.sweep(inside: worktree)

        func read(_ args: [String]) async -> String? {
            guard let result = try? await git.run(args, in: worktree), result.succeeded else { return nil }
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        /// Ignored files do not count: git already knows what the repository ignores, and a worktree Workbench
        /// made holds only what a setup, check, verify step or run produced there. Anything not ignored does.
        func untidy() async -> String? {
            guard let status = await read(["status", "--porcelain", "--untracked-files=all"]) else {
                return "git could not read its state"
            }
            return Self.statusProblem(status)
        }
        // The slow, networked question first; everything about the worktree is looked at after it, so that
        // what is removed is what was just inspected.
        if requireOrigin {
            // A thread that continued a branch shipped to that branch, so that is where the commit is looked for.
            let text = try? String(contentsOf: project.goalURL(id), encoding: .utf8)
            let remote = text.flatMap { try? GoalFile.parse($0).goal.pushTo } ?? branch
            let listed = try? await git.run(["ls-remote", "--heads", "origin", "refs/heads/\(remote)"], in: worktree)
            let tip = listed.flatMap { result -> String? in
                guard result.succeeded else { return nil }
                return Self.remoteBranchSHAIfExact(result.stdout, branch: remote)
            }
            guard tip == head else { return .kept("origin does not have \(remote) at the shipped commit") }
        }
        guard await read(["symbolic-ref", "--short", "-q", "HEAD"]) == branch else {
            return .kept("it is not on \(branch)")
        }
        guard await read(["rev-parse", "HEAD"]) == head else {
            return .kept("its HEAD is not the commit that was shipped; there is newer work in it")
        }
        if let why = await untidy() { return .kept(why) }

        if dryRun { return .removed(path: worktree.path) }
        let ignored = await ignoredEntries(in: worktree)
        do {
            try await manager.remove(threadID: id, force: false)
        } catch {
            return .kept("git would not remove it: \(Self.withoutCredentials("\(error)"))")
        }
        do { try await recordRemoval(id: id, head: head, swept: swept, ignored: ignored) } catch {
            return .kept("the worktree is removed but the log could not be written (\(error)); run ship again to record it")
        }
        return .removed(path: worktree.path)
    }

    /// Why a `git status --porcelain` listing keeps the worktree, nil when it is empty. A listing that reached
    /// the runner's output limit may have lost its tail, so it blocks too.
    static func statusProblem(_ status: String) -> String? {
        guard !status.isEmpty else { return nil }
        if status.utf8.count >= GitRunner.outputLimit - 4 {
            return "its status is too long to check in full; nothing was removed"
        }
        let first = status.split(separator: "\n").first.map(String.init) ?? ""
        return "it has files that are not committed (\(first)); nothing was removed"
    }

    /// What the removal deletes that git ignores, for the record: one entry per top-level path, at most `limit`.
    /// The listing is informative, not a gate (ignored files are disposable), so a command that fails or a
    /// listing cut at the output limit is recorded as incomplete instead of stopping the removal.
    struct IgnoredInventory: Equatable {
        var names: [String] = []
        var more = 0
        var complete = true
    }

    func ignoredEntries(in worktree: URL, limit: Int = 20) async -> IgnoredInventory {
        guard let result = try? await git.run(["status", "--porcelain", "--ignored"], in: worktree), result.succeeded else {
            return IgnoredInventory(complete: false)
        }
        return Self.inventory(of: result.stdout, limit: limit)
    }

    static func inventory(of status: String, limit: Int = 20) -> IgnoredInventory {
        // `.workbench/` holds the goal copy Workbench puts there (`WorktreeManager.goalCopyPath`): not something the thread made.
        let lines = status.split(separator: "\n").map(String.init).filter { $0.hasPrefix("!! ") && $0 != "!! .workbench/" }
        return IgnoredInventory(
            names: lines.prefix(limit).map { String($0.dropFirst(3)) }, more: max(0, lines.count - limit),
            complete: status.utf8.count < GitRunner.outputLimit - 4)
    }

    /// Appends `worktree.removed` unless another run already did: the log is read again under its lock.
    private func recordRemoval(
        id: String, head: String, swept: [Int32], ignored: IgnoredInventory = IgnoredInventory()
    ) async throws {
        try await withLog(id) { log in
            if !swept.isEmpty {
                _ = try await log.append(
                    EventKind(rawValue: "orphans.swept"), data: ["pids": .array(swept.map { .int(Int($0)) })])
            }
            let now = (try? EventLogReader.read(at: project.eventsURL(id)))?.events ?? []
            guard !now.contains(where: { $0.kind == .worktreeRemoved }) else { return }
            var data: [String: JSONValue] = ["reason": "shipped", "head_sha": .string(head)]
            if !ignored.names.isEmpty { data["ignored"] = .array(ignored.names.map { .string($0) }) }
            if ignored.more > 0 { data["ignored_more"] = .int(ignored.more) }
            if !ignored.complete { data["ignored_incomplete"] = true }
            try await log.append(.worktreeRemoved, data: .object(data))
        }
    }

    private static func remoteBranchSHAIfExact(_ output: String, branch: String) -> String? {
        try? remoteBranchSHA(in: output, branch: branch)
    }
}
