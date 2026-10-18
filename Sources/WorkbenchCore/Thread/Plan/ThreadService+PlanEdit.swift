import Foundation

/// The latest plan as `plan show` prints it.
public struct PlanView: Sendable, Equatable {
    public var plan: LatestPlan
    /// The text, nil when the file is missing or no longer what the log recorded; `problem` says which.
    public var text: String?
    public var problem: String?
    /// Whether the plan belongs to the goal as it is approved now; nil when the goal cannot be read.
    public var belongsToGoal: Bool?
    public var model: String?
    public var costUSD: Double?
}

public struct PlanEditResult: Sendable, Equatable {
    public var ref: String
    public var bytes: Int
    public var truncated: Bool
}

extension ThreadService {
    /// Where `plan edit` leaves the copy to edit.
    func planDraftURL(_ id: String) -> URL { project.threadDirectory(id).appendingPathComponent("plans/draft.md") }

    /// The latest kept plan, generated or edited, with what `show` needs. Read-only: no lock, no process.
    public func planShow(id: String) -> PlanView? {
        let events = (try? EventLogReader.read(at: project.eventsURL(id)))?.events ?? []
        guard let latest = PlanLookup.latest(in: events) else { return nil }
        let state = ThreadState.derive(from: events, id: id)
        var belongs: Bool?
        if let file = try? GoalFile.parse(String(contentsOf: project.goalURL(id), encoding: .utf8)) {
            belongs = file.goal.approval == .approved && file.goal.contentHash == latest.goalHash
        }
        var view = PlanView(
            plan: latest, text: nil, problem: nil, belongsToGoal: belongs, model: state.currentPlan?.model,
            costUSD: state.currentPlan?.costUSD)
        switch PlanLookup.text(of: latest, in: project.threadDirectory(id)) {
        case .success(let text): view.text = text
        case .failure(let problem): view.problem = "\(problem)"
        }
        return view
    }

    /// Writes the latest plan to `plans/draft.md` to be edited, and says where.
    public func planDraft(id: String) throws -> URL {
        guard let view = planShow(id: id) else { throw PlanRefusal.noPlanToEdit }
        guard let text = view.text else { throw PlanRefusal.planFileProblem(view.problem ?? "the plan cannot be read") }
        let url = planDraftURL(id)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// The draft `plan edit` left, for `--apply`.
    public func planDraftText(id: String) throws -> String {
        guard let text = try? String(contentsOf: planDraftURL(id), encoding: .utf8) else { throw PlanRefusal.noDraft }
        return text
    }

    /// Records `text` as the thread's newest plan: written as the next `plans/plan-N.md`, bounded and scrubbed like a
    /// generated one, with a `plan.edited` event. It costs nothing, runs no process and opens no numbered turn. The
    /// plan it replaces stays in the log. Held like a plan: a run, a judge or a plan makes it `busy`.
    @discardableResult
    public func planEdit(id: String, text: String) async throws -> PlanEditResult {
        if let pid = runnerPID(id: id) { throw ThreadServiceError.running(pid: pid) }
        do {
            return try await withLog(id) { log in try await self.planEditLocked(id: id, log: log, text: text) }
        } catch EventLogError.alreadyOpen { throw PlanRefusal.busy }
    }

    private func planEditLocked(id: String, log: EventLogWriter, text: String) async throws -> PlanEditResult {
        let events = (try? EventLogReader.read(at: project.eventsURL(id)))?.events ?? []
        let state = ThreadState.derive(from: events, id: id)
        if let decision = state.decision { throw ThreadServiceError.threadEnded(decision) }
        let goal: Goal
        do {
            goal = try GoalFile.parse(String(contentsOf: project.goalURL(id), encoding: .utf8)).goal
        } catch { throw PlanRefusal.goalUnreadable("\(error)") }
        guard goal.approval == .approved else { throw PlanRefusal.goalNotApproved(goal.approval) }
        guard let stored = Plan.stored(from: text) else { throw PlanRefusal.emptyEdit }
        let latest = PlanLookup.latest(in: events)
        if latest?.sha256 == Plan.sha256(stored.text) { throw PlanRefusal.unchangedEdit }

        let recorded = events.last { $0.kind == .worktreeCreated }?.data["base_commit"]?.stringValue
        var base = latest?.baseCommit ?? recorded
        if base == nil { base = try? await WorktreeManager(repoRoot: project.root, git: git).commit(of: goal.base) }

        let ref = "plans/plan-\(Self.nextPlanNumber(events)).md"
        let url = project.threadDirectory(id).appendingPathComponent(ref)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try stored.text.write(to: url, atomically: true, encoding: .utf8)
        var data: [String: JSONValue] = [
            "plan_ref": .string(ref), "sha256": .string(Plan.sha256(stored.text)), "bytes": .int(stored.text.utf8.count),
            "truncated": .bool(stored.truncated), "from_sha256": latest.map { .string($0.sha256) } ?? .null,
            "goal_hash": .string(goal.contentHash),
        ]
        if let base { data["base_commit"] = .string(base) }
        try await log.append(.planEdited, turn: state.lastTurn, data: .object(data))
        try? FileManager.default.removeItem(at: planDraftURL(id))
        return PlanEditResult(ref: ref, bytes: stored.text.utf8.count, truncated: stored.truncated)
    }
}
