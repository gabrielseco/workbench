import Foundation

/// The worktree a handed-off goal works in, and the bound its approval set.
public struct PreparedHandoff: Equatable, Sendable {
    public var worktree: URL
    /// The approved goal's `turn_timeout_min`: the session is stopped after it.
    public var turnTimeoutMin: Int
}

extension ThreadService {
    /// What a goal handed to another tool (Herdr) is prepared with. The goal is approved first; a thread with no worktree gets one
    /// cut as a run cuts it, recorded with `worktree.created`, so a later run, review or accept finds the same base. The approved goal
    /// and its screenshots are copied in at `WorktreeManager.goalCopyPath`, where the session is told to read it. A goal with a dollar
    /// cap is refused before anything is approved or cut: an interactive session cannot enforce one.
    public func prepareHandoff(id: String) async throws -> PreparedHandoff {
        guard SafeNames.isThreadID(id) else { throw ThreadStoreError.invalidName(id) }
        if let pid = runnerPID(id: id) { throw ThreadServiceError.running(pid: pid) }
        let text = try? String(contentsOf: project.goalURL(id), encoding: .utf8)
        if let text, (try? GoalFile.parse(text))?.goal.budgetUSD != nil {
            throw ThreadServiceError.budgetNeedsCap(provider: Self.handoffAgent)
        }
        let file = try await approve(id: id)
        // The file can change between the read above and the approval; what was approved is what counts.
        if file.goal.budgetUSD != nil { throw ThreadServiceError.budgetNeedsCap(provider: Self.handoffAgent) }
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
        return PreparedHandoff(worktree: manager.path(for: id), turnTimeoutMin: file.goal.turnTimeoutMin)
    }

    static let handoffAgent = "An interactive Claude session in Herdr"
}
