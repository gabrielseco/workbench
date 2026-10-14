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
        guard manager.exists(id) else { return .alreadyGone }
        let worktree = manager.path(for: id)
        let branch = WorktreeManager.branch(for: id)
        if let pid = runnerPID(id: id) { return .kept("a run is still active (pid \(pid))") }

        func read(_ args: [String]) async -> String? {
            guard let result = try? await git.run(args, in: worktree), result.succeeded else { return nil }
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard await read(["symbolic-ref", "--short", "-q", "HEAD"]) == branch else {
            return .kept("it is not on \(branch)")
        }
        guard await read(["rev-parse", "HEAD"]) == head else {
            return .kept("its HEAD is not the commit that was shipped; there is newer work in it")
        }
        guard let status = await read(["status", "--porcelain", "--ignored", "--untracked-files=all"]) else {
            return .kept("git could not read its state")
        }
        if !status.isEmpty {
            let first = status.split(separator: "\n").first.map(String.init) ?? ""
            return .kept("it has files that are not committed or are ignored (\(first)); nothing was removed")
        }
        // Not just "the branch is on origin": the commit that is there must be this one.
        let listed = try? await git.run(["ls-remote", "--heads", "origin", "refs/heads/\(branch)"], in: worktree)
        let tip = listed.flatMap { result -> String? in
            guard result.succeeded else { return nil }
            return Self.remoteBranchSHAIfExact(result.stdout, branch: branch)
        }
        guard tip == head else { return .kept("origin does not have \(branch) at the shipped commit") }

        let swept = OrphanSweeper.sweep(inside: worktree)
        do {
            try await withLog(id) { log in
                if !swept.isEmpty {
                    _ = try await log.append(
                        EventKind(rawValue: "orphans.swept"), data: ["pids": .array(swept.map { .int(Int($0)) })])
                }
                try await manager.remove(threadID: id, force: false)
                try await log.append(
                    .worktreeRemoved, data: ["reason": "shipped", "head_sha": .string(head)])
            }
        } catch {
            return .kept("git would not remove it: \(Self.withoutCredentials("\(error)"))")
        }
        return .removed(path: worktree.path)
    }

    private static func remoteBranchSHAIfExact(_ output: String, branch: String) -> String? {
        try? remoteBranchSHA(in: output, branch: branch)
    }
}
