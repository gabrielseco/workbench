import Foundation

// MARK: Abandon

extension ThreadService {
    /// Ends the thread without accepting its work: records the decision and removes the worktree. The branch
    /// is kept, so nothing the model committed is lost, and what was not committed (modified, staged and
    /// untracked files, not ignored ones) is first written to `abandon.patch` in the thread's folder. If that
    /// cannot be done (too large, a failed write) nothing is removed and the thread stays active. Git refuses to
    /// remove a dirty worktree, so after the save the removal is forced; what stands in for git's check is that
    /// the worktree's tree is read again first and must be the one the patch was taken from, and that no run is
    /// still working in it. `force` lifts git's refusals for a worktree that had nothing to save.
    @discardableResult
    public func abandon(id: String, force: Bool = false) async throws -> SavedPatch? {
        try await abandon(id: id, force: force, afterSave: nil)
    }

    /// `afterSave` runs between the patch and the removal; only tests pass one, to write into the worktree there.
    func abandon(id: String, force: Bool, afterSave: (@Sendable () async throws -> Void)?) async throws -> SavedPatch? {
        if let decision = ThreadStore(project: project).state(of: id).decision {
            throw ThreadServiceError.threadEnded(decision)
        }
        if let pid = runnerPID(id: id) { throw ThreadServiceError.running(pid: pid) }
        // The log's lock is held from the checks to the decision, as `judge` and `pr-review` do: a run that starts
        // meanwhile cannot have its worktree removed from under it, and a second abandon waits or is refused.
        return try await withLog(id) { log in
            if let decision = ThreadStore(project: project).state(of: id).decision {
                throw ThreadServiceError.threadEnded(decision)
            }
            if let pid = runnerPID(id: id) { throw ThreadServiceError.running(pid: pid) }
            let manager = WorktreeManager(repoRoot: project.root, git: git)
            var saved: SavedPatch?
            if manager.exists(id) {
                // Children a dead runner left in the worktree would outlive it, and write into it while it is saved.
                let swept = OrphanSweeper.sweep(inside: manager.path(for: id))
                if !swept.isEmpty {
                    _ = try await log.append(
                        EventKind(rawValue: "orphans.swept"), data: ["pids": .array(swept.map { .int(Int($0)) })])
                }
                let base = baseCommit(of: id)
                saved = try await savePatch(id: id, manager: manager, base: base)
                try await afterSave?()
                if let saved {
                    let now = await ProofIdentity.of(worktree: manager.path(for: id), git: git, attributesFrom: base)
                    guard now?.tree == saved.tree else {
                        throw ThreadServiceError.abandonNotSaved(
                            "the worktree changed while its changes were being saved")
                    }
                    // On record before the removal, so a crash between the two cannot lose where the work went.
                    try await log.append(.abandonSaved, data: Self.savedData(saved))
                    try await manager.remove(threadID: id, force: true)
                } else {
                    try await manager.remove(threadID: id, force: force)
                }
            }
            _ = try await log.recoverOrphanedTurn()
            _ = try await log.recoverOrphanedCheck()
            _ = try await log.recoverOrphanedVerify()
            _ = try await log.recoverOrphanedEvaluations()
            try await log.append(.reviewDecision, data: ["decision": "abandoned", "by": "user"])
            return saved
        }
    }

    /// Where `abandon` keeps what was not committed, relative to the thread's folder.
    public static let abandonPatchName = "abandon.patch"
    /// What the index held that the working tree did not, when there was any.
    public static let abandonStagedPatchName = "abandon-staged.patch"

    private static func savedData(_ saved: SavedPatch) -> JSONValue {
        var data: [String: JSONValue] = [
            "path": .string(abandonPatchName), "bytes": .int(saved.bytes), "sha256": .string(saved.sha256),
            "tree": .string(saved.tree), "head": .string(saved.head),
        ]
        if let staged = saved.staged {
            data["staged_path"] = .string(abandonStagedPatchName)
            data["staged_bytes"] = .int(staged.bytes)
            data["staged_sha256"] = .string(staged.sha256)
        }
        return .object(data)
    }

    private func baseCommit(of id: String) -> String? {
        let events = (try? EventLogReader.read(at: project.eventsURL(id)))?.events ?? []
        return events.last(where: { $0.kind == .worktreeCreated })?.data["base_commit"]?.stringValue
    }

    private func savePatch(id: String, manager: WorktreeManager, base: String?) async throws -> SavedPatch? {
        do {
            return try await WorktreePatch.save(
                worktree: manager.path(for: id),
                to: project.threadDirectory(id).appendingPathComponent(Self.abandonPatchName),
                stagedTo: project.threadDirectory(id).appendingPathComponent(Self.abandonStagedPatchName), git: git,
                attributesFrom: base)
        } catch let error as WorktreePatchError {
            throw ThreadServiceError.abandonNotSaved(error.description)
        }
    }
}
