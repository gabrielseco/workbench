import Foundation

extension ThreadRunner {
    /// Closes a check or verify step left open by a runner that died.
    func recoverOrphanedChecks(log: EventLogWriter) async throws {
        if let recovered = try await log.recoverOrphanedCheck() { notify(.recoveredOrphanedCheck(recovered.turn)) }
        _ = try await log.recoverOrphanedVerify()
        try await Plan.recoverOrphan(log: log, project: project, threadID: threadID, git: git)
        try await Verifier.recoverOrphan(log: log, worktree: worktreeManager.path(for: threadID))
    }

    /// The prompt built from the goal, and what `turn.started` records about it (`instructions`, `plan`). It carries
    /// the project's instructions as they were at the base commit: not the main checkout, and not the worktree,
    /// which the run may already have edited.
    func firstPrompt(
        goal: Goal, config: Config, baseCommit: String?, options: RunOptions
    ) async -> (prompt: String, info: [String: JSONValue]) {
        var loaded: ProjectInstructions?
        if config.projectInstructions, let baseCommit {
            loaded = await ProjectInstructions.load(git: git, repo: project.root, commit: baseCommit)
        }
        var verifierRuns = false
        if let verifier = config.verifier, let baseCommit {
            let skill = await VerifierSkill.load(git: git, repo: project.root, commit: baseCommit, path: verifier.skill)
            if case .success = skill { verifierRuns = true }
        }
        let chosen = planForFirstPrompt(goal: goal, baseCommit: baseCommit, options: options)
        let prompt = PromptBuilder.firstPrompt(
            goal: goal, checkCommand: config.checkCommand, instructions: loaded,
            verifies: config.verifyCommand != nil || verifierRuns,
            plan: chosen.plan)
        return (prompt, ["instructions": loaded?.eventData ?? .null, "plan": chosen.info])
    }

    /// The plan the first prompt carries and what `turn.started` says about it: `{sha256, bytes, source}`, or null
    /// when the run has none (there is none, it is for another version of the goal, its file changed, or
    /// `--no-plan`). A plan that exists and is left out is said so, once, as a note.
    func planForFirstPrompt(goal: Goal, baseCommit: String?, options: RunOptions) -> (plan: PlanForRun?, info: JSONValue) {
        if options.noPlan { return (nil, .null) }
        let events = (try? EventLogReader.read(at: project.eventsURL(threadID)))?.events ?? []
        let choice = PlanLookup.choose(
            events: events, goalHash: goal.contentHash, currentBase: baseCommit,
            threadDirectory: project.threadDirectory(threadID))
        switch choice {
        case .none: return (nil, .null)
        case .left(let why):
            notify(.advisory(why))
            return (nil, .null)
        case .use(let plan):
            return (
                plan,
                ["sha256": .string(plan.sha256), "bytes": .int(plan.bytes), "source": .string(plan.source.rawValue)]
            )
        }
    }

    // MARK: Classification (pure, tested directly)

    static func classify(exit: ProcessExit?, result: [String: Any]?) -> RunResult {
        guard let exit else { return .failed }
        switch exit.cause {
        case .stopped: return .stopped
        case .timedOut: return .timedOut
        case .natural: break
        }
        if case .signaled = exit.termination { return .failed }
        guard let result else { return .failed }

        let subtype = result["subtype"] as? String
        let terminal = result["terminal_reason"] as? String
        if subtype == "error_max_budget_usd" || terminal == "budget_exhausted" { return .budgetExceeded }
        // A success line from a process that then exited non-zero is not a success.
        if case .exited(let code) = exit.termination, code != 0 { return .failed }
        if subtype == "success", result["is_error"] as? Bool != true { return .succeeded }
        return .failed
    }
}
