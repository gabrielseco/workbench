import Foundation

extension ThreadService {
    /// The worktree a goal handed to another tool (Herdr) works in. The goal is approved first; a thread with no worktree gets one cut
    /// as a run cuts it, recorded with `worktree.created`, so a later run, review or accept finds the same base. The approved goal and
    /// its screenshots are copied in at `WorktreeManager.goalCopyPath`, where the session is told to read it.
    public func prepareHandoff(id: String) async throws -> URL {
        guard SafeNames.isThreadID(id) else { throw ThreadStoreError.invalidName(id) }
        if let pid = runnerPID(id: id) { throw ThreadServiceError.running(pid: pid) }
        let file = try await approve(id: id)
        let copy = (try? Config.load(from: project.configURL))?.copy ?? []
        let manager = WorktreeManager(repoRoot: project.root, git: git)
        if !manager.exists(id) {
            try await withLog(id) { log in
                if let decision = ThreadStore(project: project).state(of: id).decision {
                    throw ThreadServiceError.threadEnded(decision)
                }
                let created = try await manager.create(
                    threadID: id, base: file.goal.base, fetching: file.goal.pushTo, copying: copy)
                try await log.append(.worktreeCreated, data: created.eventData)
            }
        }
        // The session is told to read this file: without it there is nothing to hand over.
        if case .skipped(let why) = await manager.writeGoalCopy(file.text, for: id) {
            throw ThreadServiceError.goalNotCopied(why)
        }
        _ = await manager.writeAttachmentCopies(GoalAttachments.stored(in: project.threadDirectory(id)), for: id)
        return manager.path(for: id)
    }
}
