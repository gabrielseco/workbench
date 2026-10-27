import Foundation

extension ThreadService {
    /// The agent a plan or PR description turn runs on, or why it is refused before anything starts: no adapter, or a
    /// provider with no dollar cap that `allow_unpriced = false` forbids (the rule judge and review follow).
    static func readOnlyAgent(
        role: AgentRole, agent: ResolvedAgent, config: Config, cap: Decimal, environment: [String: String]
    ) -> Result<any ReadOnlyAgent, AgentFailure> {
        guard let provider = config.agentProvider(agent.provider),
            let chosen = config.readOnlyAgent(agent.provider, environment: environment)
        else {
            return .failure(AgentFailure(.unsupportedCapability, "there is no adapter for \(agent.provider)", retry: .afterFix))
        }
        let spend = AgentSpendPolicy.spend(
            role: role, agent: agent, capabilities: provider.capabilities, cap: cap, legacy: false,
            table: config.allowUnpricedTable(role))
        if case .failure(let refusal) = spend { return .failure(refusal) }
        return .success(chosen)
    }

    /// What a PR description or refresh turn came to: the model's own text, or why there is none, and the command as
    /// it is logged.
    struct PRTurnOutcome {
        var text: String?
        var failure: String?
        var argv: [String]
    }

    /// Runs a PR description or refresh turn on `[agents.ship]`'s provider, with no tools: the prompt is all it has.
    /// On Claude it is the command it always was, in the worktree; on Codex it runs in an empty folder outside the
    /// repository, removed when the turn ends.
    func runPRTurn(
        id: String, worktree: URL, prompt: String, config: Config, environment: [String: String], timeout: TimeInterval,
        attach: @Sendable (ProcessRun) -> Void
    ) async -> PRTurnOutcome {
        let agent = config.resolvedShipAgent
        let chosen: any ReadOnlyAgent
        let picked = Self.readOnlyAgent(
            role: .ship, agent: agent, config: config, cap: PRDescriber.budgetUSD, environment: environment)
        switch picked {
        case .success(let found): chosen = found
        case .failure(let refusal): return PRTurnOutcome(failure: refusal.message, argv: [])
        }
        let scratch = prTurnScratch(id)
        let root = OrphanSweeper.realPath(project.root)
        if agent.provider != .claude, Self.isInside(OrphanSweeper.realPath(scratch.url.deletingLastPathComponent()), root: root) {
            return PRTurnOutcome(failure: "the temporary folder is inside the repository, so the turn would see it", argv: [])
        }
        let request = ReadOnlyRequest(
            prompt: prompt, workingDirectory: worktree, model: agent.model, budget: PRDescriber.budgetUSD,
            timeout: timeout, reasoningEffort: agent.reasoningEffort, tools: .none, scratch: scratch,
            turn: "PR description turn")
        let shown = chosen.shownArguments(for: request)
        if let why = chosen.unavailable() { return PRTurnOutcome(failure: why, argv: shown) }
        if let pid = runnerPID(id: id), pid != getpid() {
            return PRTurnOutcome(failure: "another command is using this thread (pid \(pid))", argv: shown)
        }
        // This process is the thread's live holder while the turn runs: `stop` reaches it, a run, a judge or a plan is
        // refused.
        try? writeHolderMarker(id)
        defer { try? FileManager.default.removeItem(at: project.runnerURL(id)) }
        let answer = await chosen.run(request, attach: attach)
        guard let text = answer.text else { return PRTurnOutcome(failure: answer.failure ?? "no answer", argv: shown) }
        return PRTurnOutcome(text: text, argv: shown)
    }

    /// True for the repository root itself and for anything under it (a `TMPDIR` that names the root is inside it too).
    static func isInside(_ path: String, root: String) -> Bool { path == root || path.hasPrefix(root + "/") }

    /// Where a PR description or refresh turn on Codex runs: in the system's temporary folder, outside the repository,
    /// and named for the thread, so the next command finds one a killed Workbench left.
    func prTurnScratch(_ id: String) -> TurnScratch {
        let key = Plan.sha256(project.threadDirectory(id).standardizedFileURL.path).prefix(16)
        return TurnScratch(url: FileManager.default.temporaryDirectory.appendingPathComponent("workbench-pr-\(key)"))
    }

    /// Where a plan turn on Codex writes its answer: beside the checkout it reads, not inside it.
    func planScratch(_ id: String) -> TurnScratch {
        TurnScratch(url: planDirectory(id).appendingPathComponent("answer", isDirectory: true))
    }
}
