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
    /// (ignored files count), at the commit `pr.opened` recorded, that commit is what `origin` has, and no
    /// run is active. Never forces. The branch is kept. Records `worktree.removed` and nothing else.
    public func cleanShipped(id: String, gh: GitRunner?) async -> ShipCleanup {
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
        let swept = OrphanSweeper.sweep(inside: worktree)

        func read(_ args: [String]) async -> String? {
            guard let result = try? await git.run(args, in: worktree), result.succeeded else { return nil }
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func untidy() async -> String? {
            guard let status = await read(["status", "--porcelain", "--ignored", "--untracked-files=all"]) else {
                return "git could not read its state"
            }
            guard !status.isEmpty else { return nil }
            let first = status.split(separator: "\n").first.map(String.init) ?? ""
            return "it has files that are not committed or are ignored (\(first)); nothing was removed"
        }
        // The slow, networked question first; everything about the worktree is looked at after it, so that
        // what is removed is what was just inspected.
        let listed = try? await git.run(["ls-remote", "--heads", "origin", "refs/heads/\(branch)"], in: worktree)
        let tip = listed.flatMap { result -> String? in
            guard result.succeeded else { return nil }
            return Self.remoteBranchSHAIfExact(result.stdout, branch: branch)
        }
        guard tip == head else { return .kept("origin does not have \(branch) at the shipped commit") }
        guard await read(["symbolic-ref", "--short", "-q", "HEAD"]) == branch else {
            return .kept("it is not on \(branch)")
        }
        guard await read(["rev-parse", "HEAD"]) == head else {
            return .kept("its HEAD is not the commit that was shipped; there is newer work in it")
        }
        if let why = await untidy() { return .kept(why) }

        do {
            try await manager.remove(threadID: id, force: false)
        } catch {
            return .kept("git would not remove it: \(Self.withoutCredentials("\(error)"))")
        }
        do { try await recordRemoval(id: id, head: head, swept: swept) } catch {
            return .kept("the worktree is removed but the log could not be written (\(error)); run ship again to record it")
        }
        return .removed(path: worktree.path)
    }

    /// Appends `worktree.removed` unless another run already did: the log is read again under its lock.
    private func recordRemoval(id: String, head: String, swept: [Int32]) async throws {
        try await withLog(id) { log in
            if !swept.isEmpty {
                _ = try await log.append(
                    EventKind(rawValue: "orphans.swept"), data: ["pids": .array(swept.map { .int(Int($0)) })])
            }
            let now = (try? EventLogReader.read(at: project.eventsURL(id)))?.events ?? []
            guard !now.contains(where: { $0.kind == .worktreeRemoved }) else { return }
            try await log.append(.worktreeRemoved, data: ["reason": "shipped", "head_sha": .string(head)])
        }
    }

    private static func remoteBranchSHAIfExact(_ output: String, branch: String) -> String? {
        try? remoteBranchSHA(in: output, branch: branch)
    }
}
