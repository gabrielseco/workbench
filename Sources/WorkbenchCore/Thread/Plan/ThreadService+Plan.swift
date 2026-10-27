import Foundation

/// What `workbench plan` came to. A failed plan is a result, not a thrown error: nothing depends on it, so a
/// missing `claude`, a timeout, a budget stop or an empty answer only mean there is no plan this time.
public struct PlanResult: Sendable, Equatable {
    /// The stored plan text, nil when there is none.
    public var text: String?
    /// Where it is, relative to the thread's folder (`plans/plan-1.md`).
    public var ref: String?
    public var costUSD: Double?
    public var truncated: Bool
    /// Why there is no plan.
    public var failure: String?
    /// Something to tell the person that did not stop the plan, such as a checkout that could not be removed.
    public var warning: String?
}

public enum PlanRefusal: Error, Equatable, Sendable, CustomStringConvertible {
    case goalUnreadable(String)
    case goalNotApproved(ApprovalState)
    case alreadyPlanned
    case invalidModel(String)
    case busy
    case noPlanToEdit
    case planFileProblem(String)
    case emptyEdit
    case unchangedEdit
    case noDraft
    case fileUnreadable(String)
    case baseUnknown

    public var description: String {
        switch self {
        case .goalUnreadable(let why): "the goal could not be read: \(why)"
        case .goalNotApproved(.stale):
            "the goal changed since it was approved: run `workbench goal approve` again, then plan."
        case .goalNotApproved:
            "the goal is not approved: run `workbench goal approve` first. A plan costs money, so it only runs "
                + "on a goal you have approved."
        case .alreadyPlanned:
            "this goal has a plan already (`workbench log` shows it). Pass --again to make another."
        case .invalidModel: "--model needs a model name or alias like \"opus\""
        case .busy: "another command is using this thread (a run, a judge or another plan); try again when it ends."
        case .noPlanToEdit:
            "this thread has no plan to edit: run `workbench plan` first, or give one with `plan edit --from <file>`."
        case .planFileProblem(let why): why
        case .emptyEdit: "the edited plan is empty; nothing was recorded."
        case .unchangedEdit: "the plan is the same as the latest one; nothing was recorded."
        case .noDraft: "there is no draft to apply: run `workbench plan edit`, edit plans/draft.md, then `plan edit --apply`."
        case .fileUnreadable(let why): "the file could not be read: \(why)"
        case .baseUnknown:
            "the goal's base commit could not be read, so the plan cannot be tied to one; nothing was recorded."
        }
    }
}

/// A plan as written to the thread's folder.
private struct SavedPlan {
    var text: String
    var truncated: Bool
    var ref: String
}

extension ThreadService {
    /// Where a plan turn's checkout lives; a `claude` a killed plan left is found by this folder.
    func planDirectory(_ id: String) -> URL { project.threadDirectory(id).appendingPathComponent("plan") }

    /// The number of the next plan file: one more than the plans kept so far, generated or edited.
    static func nextPlanNumber(_ events: [Event]) -> Int {
        events.filter { ($0.kind == .planEnded || $0.kind == .planEdited) && $0.data["plan_ref"] != nil }.count + 1
    }

    /// Closes a plan left open by a process that died, and ends what it left behind (see `Plan.recoverOrphan`).
    func closeOrphanedPlan(id: String, log: EventLogWriter) async throws {
        try await Plan.recoverOrphan(log: log, folder: planDirectory(id), repoRoot: project.root, git: git)
        // A Codex description turn has no open event to recover; its folder names the Workbench that made it.
        prTurnScratch(id).clearIfAbandoned()
        try await closeOrphanedVerifier(id: id, log: log)
    }

    /// Runs the plan turn on the approved goal and records `plan.started` and `plan.ended`. Read-only and separate
    /// from the work: it reads a throwaway checkout of the base commit, has its own session and budget, opens no
    /// numbered turn, and nothing in Workbench acts on what it says (yet: `run` does not read it).
    ///
    /// The thread's log is held from the checks to the record, so a plan, a judge and a run cannot spend on the
    /// same thread at once: the second is refused as `busy`.
    ///
    /// - Parameters:
    ///   - agent: who answers; the provider `[agents.plan]` names unless a test says otherwise.
    ///   - attach: called with the running process, so the caller can stop it (Ctrl-C).
    public func plan(
        id: String, config: Config, again: Bool = false, budget: Decimal = Plan.budgetUSD, model: String? = nil,
        agent: ReadOnlyAgent? = nil, environment: [String: String] = ProcessInfo.processInfo.environment,
        timeout: TimeInterval = Plan.timeout, attach: @Sendable (ProcessRun) -> Void = { _ in }
    ) async throws -> PlanResult {
        if let model, !SafeNames.isModelName(model) { throw PlanRefusal.invalidModel(model) }
        if let pid = runnerPID(id: id) { throw ThreadServiceError.running(pid: pid) }
        do {
            return try await withLog(id) { log in
                try await self.planLocked(
                    id: id, log: log, config: config, again: again, budget: budget, model: model, agent: agent,
                    environment: environment, timeout: timeout, attach: attach)
            }
        } catch EventLogError.alreadyOpen { throw PlanRefusal.busy }
    }

    private func planLocked(
        id: String, log: EventLogWriter, config: Config, again: Bool, budget: Decimal, model: String?,
        agent given: ReadOnlyAgent?, environment: [String: String], timeout: TimeInterval,
        attach: @Sendable (ProcessRun) -> Void
    ) async throws -> PlanResult {
        // `withLog` has already closed a plan whose process died, before any refusal below.
        let events = (try? EventLogReader.read(at: project.eventsURL(id)))?.events ?? []
        if let decision = ThreadState.derive(from: events, id: id).decision { throw ThreadServiceError.threadEnded(decision) }
        let goal: Goal
        do {
            goal = try GoalFile.parse(String(contentsOf: project.goalURL(id), encoding: .utf8)).goal
        } catch { throw PlanRefusal.goalUnreadable("\(error)") }
        guard goal.approval == .approved else { throw PlanRefusal.goalNotApproved(goal.approval) }

        let hash = goal.contentHash
        let planned = events.contains {
            $0.kind == .planEnded && $0.data["ok"] == true && $0.data["goal_hash"]?.stringValue == hash
        }
        if planned && !again { throw PlanRefusal.alreadyPlanned }
        let turn = ThreadState.derive(from: events, id: id).lastTurn
        let planAgent = config.resolvedPlanAgent(modelFlag: model)

        let manager = WorktreeManager(repoRoot: project.root, git: git)
        let recorded = events.last { $0.kind == .worktreeCreated }?.data["base_commit"]?.stringValue
        var resolved = recorded
        var baseProblem: String?
        if resolved == nil {
            do { resolved = try await manager.commit(of: goal.base) } catch { baseProblem = "\(error)" }
        }
        guard let commit = resolved else {
            return try await recordPlan(
                log, agent: planAgent, turn: turn, hash: hash, base: nil,
                failure: baseProblem ?? "the base commit is unknown", argv: nil)
        }

        let request = ReadOnlyRequest(
            prompt: "", workingDirectory: planDirectory(id), model: planAgent.model, budget: budget, timeout: timeout,
            reasoningEffort: planAgent.reasoningEffort, scratch: planScratch(id))
        var loaded: ProjectInstructions?
        if config.projectInstructions {
            loaded = await ProjectInstructions.load(git: git, repo: project.root, commit: commit)
        }
        let prompt = Plan.prompt(for: PlanInput(goal: goal, baseCommit: commit, instructions: loaded))
        var asked = request
        asked.prompt = prompt
        let agent: ReadOnlyAgent
        if let given {
            agent = given
        } else {
            switch Self.readOnlyAgent(role: .plan, agent: planAgent, config: config, cap: budget, environment: environment) {
            case .success(let chosen): agent = chosen
            case .failure(let refusal):
                return try await recordPlan(
                    log, agent: planAgent, turn: turn, hash: hash, base: commit, failure: refusal.message, argv: nil)
            }
        }
        let shown = agent.shownArguments(for: asked)
        if let why = agent.unavailable() {
            return try await recordPlan(
                log, agent: planAgent, turn: turn, hash: hash, base: commit, failure: why, argv: shown)
        }

        // The attempt is on record before anything is spent, and this process is the thread's live holder while it
        // runs (`stop` reaches it, a run, a judge or another plan is refused).
        try? writeHolderMarker(id)
        defer { try? FileManager.default.removeItem(at: project.runnerURL(id)) }
        // After the marker, so a doctor that starts now sees this plan, and this plan sees a doctor that is running.
        try ThreadStore(project: project).requireNoDoctor()
        try await log.append(
            .planStarted, turn: turn,
            data: .object(
                Self.agentFields(
                    planAgent,
                    [
                        "argv": .array(shown.map { .string($0) }), "base_commit": .string(commit),
                        "goal_hash": .string(hash),
                    ])))

        let folder = planDirectory(id)
        let checkout = folder.appendingPathComponent("checkout")
        // Anything left in the folder was left by a plan that is already closed (above); ended again to be sure.
        OrphanSweeper.sweep(inside: folder)
        await manager.removeDetached(at: checkout)
        planScratch(id).clear()
        let began = Date()
        var answer: ReadOnlyAnswer
        do {
            try await manager.addDetached(at: checkout, commit: commit)
            asked.workingDirectory = checkout
            answer = await agent.run(asked, attach: attach)
        } catch {
            answer = ReadOnlyAnswer(
                text: nil, costUSD: nil, failure: "the base commit could not be checked out: \(error)")
        }
        OrphanSweeper.sweep(inside: folder)
        planScratch(id).clear()
        var warning: String?
        if !(await manager.removeDetached(at: checkout)) {
            warning = "the checkout of the base commit could not be removed; the next plan clears it"
        }
        let elapsed = Int(Date().timeIntervalSince(began) * 1000)

        guard let raw = answer.text else {
            return try await recordPlan(
                log, agent: planAgent, turn: turn, hash: hash, base: commit, cost: answer.costUSD,
                failure: answer.failure ?? "no answer", argv: shown, durationMs: elapsed, warning: warning)
        }
        guard let stored = Plan.stored(from: raw) else {
            return try await recordPlan(
                log, agent: planAgent, turn: turn, hash: hash, base: commit, cost: answer.costUSD,
                failure: "the plan was empty", argv: shown, durationMs: elapsed, warning: warning)
        }
        let ref = "plans/plan-\(Self.nextPlanNumber(events)).md"
        let url = project.threadDirectory(id).appendingPathComponent(ref)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try stored.text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            return try await recordPlan(
                log, agent: planAgent, turn: turn, hash: hash, base: commit, cost: answer.costUSD,
                failure: "the plan could not be written: \(error.localizedDescription)", argv: shown, durationMs: elapsed,
                warning: warning)
        }
        return try await recordPlan(
            log, agent: planAgent, turn: turn, hash: hash, base: commit, cost: answer.costUSD,
            stored: SavedPlan(text: stored.text, truncated: stored.truncated, ref: ref), argv: shown, durationMs: elapsed,
            warning: warning)
    }

    private func recordPlan(
        _ log: EventLogWriter, agent: ResolvedAgent, turn: Int, hash: String, base: String?, cost: Double? = nil,
        stored: SavedPlan? = nil, failure: String? = nil, argv: [String]?,
        durationMs: Int? = nil, warning: String? = nil
    ) async throws -> PlanResult {
        var data: [String: JSONValue] = ["ok": .bool(stored != nil), "goal_hash": .string(hash)]
        if let base { data["base_commit"] = .string(base) }
        if let argv, !argv.isEmpty { data["argv"] = .array(argv.map { .string($0) }) }
        if let cost { data["cost_usd"] = .double(cost) }
        if let durationMs { data["duration_ms"] = .int(durationMs) }
        if let stored {
            data["plan_ref"] = .string(stored.ref)
            data["sha256"] = .string(Plan.sha256(stored.text))
            data["bytes"] = .int(stored.text.utf8.count)
            data["truncated"] = .bool(stored.truncated)
        }
        let reason = failure.map { Self.withoutCredentials(PRBodyBuilder.scrub($0)) }
        if let reason { data["reason"] = .string(reason) }
        if let warning { data["warning"] = .string(warning) }
        try await log.append(.planEnded, turn: turn, data: .object(Self.agentFields(agent, data)))
        return PlanResult(
            text: stored?.text, ref: stored?.ref, costUSD: cost, truncated: stored?.truncated ?? false, failure: reason,
            warning: warning)
    }
}
