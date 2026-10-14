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
            guard !removedRecorded else { return .alreadyGone }
            do {
                try await withLog(id) { log in
                    try await log.append(.worktreeRemoved, data: ["reason": "shipped", "head_sha": .string(head)])
                }
            } catch { return .kept("the worktree is gone but the log could not be written: \(error)") }
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
        guard await read(["symbolic-ref", "--short", "-q", "HEAD"]) == branch else {
            return .kept("it is not on \(branch)")
        }
        guard await read(["rev-parse", "HEAD"]) == head else {
            return .kept("its HEAD is not the commit that was shipped; there is newer work in it")
        }
        if let why = await untidy() { return .kept(why) }
        // Not just "the branch is on origin": the commit that is there must be this one.
        let listed = try? await git.run(["ls-remote", "--heads", "origin", "refs/heads/\(branch)"], in: worktree)
        let tip = listed.flatMap { result -> String? in
            guard result.succeeded else { return nil }
            return Self.remoteBranchSHAIfExact(result.stdout, branch: branch)
        }
        guard tip == head else { return .kept("origin does not have \(branch) at the shipped commit") }
        if let why = await untidy() { return .kept(why) }

        do {
            try await manager.remove(threadID: id, force: false)
        } catch {
            return .kept("git would not remove it: \(Self.withoutCredentials("\(error)"))")
        }
        do {
            try await withLog(id) { log in
                if !swept.isEmpty {
                    _ = try await log.append(
                        EventKind(rawValue: "orphans.swept"), data: ["pids": .array(swept.map { .int(Int($0)) })])
                }
                try await log.append(.worktreeRemoved, data: ["reason": "shipped", "head_sha": .string(head)])
            }
        } catch {
            return .kept("the worktree is removed but the log could not be written (\(error)); run ship again to record it")
        }
        return .removed(path: worktree.path)
    }

    private static func remoteBranchSHAIfExact(_ output: String, branch: String) -> String? {
        try? remoteBranchSHA(in: output, branch: branch)
    }
}
