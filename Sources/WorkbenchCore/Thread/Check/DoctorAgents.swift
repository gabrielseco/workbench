import Foundation

/// Something `doctor` found about a responsibility's provider before anything is spawned. A `problem` is what the
/// responsibility would be refused or fail on; a `note` is a limit or a setting that changes nothing.
public struct DoctorAgentIssue: Sendable, Equatable {
    public enum Severity: String, Sendable { case problem, note }

    public var role: AgentRole
    /// `policy_without_controls`, `missing_executable`, `budget_without_cap`, `unpriced_not_allowed`, `unconfined_reads` or
    /// `setting_unused`.
    public var kind: String
    public var severity: Severity
    public var message: String
}

extension DoctorAgent {
    public var problems: [DoctorAgentIssue] { issues.filter { $0.severity == .problem } }
}

extension DoctorReport {
    /// Every problem of every responsibility, goal drafting first.
    public var agentProblems: [DoctorAgentIssue] { agents.flatMap(\.problems) }
}

/// The goal doctor checks: the one of the project's active thread.
struct DoctorGoal {
    var thread: String
    var spend: AgentSpend
    var turnTimeoutMin: Int
    /// The goal's own `model`, which wins over the config when a run resolves its agent.
    var model: String?
    var approvedFor: AgentUse?

    var spendLine: String? { spend == .timeoutOnly ? "no dollar cap: bounded by \(turnTimeoutMin) min per turn" : nil }
}

extension Doctor {
    /// The policy each responsibility needs from its adapter.
    static func policy(for role: AgentRole) -> AgentPolicy { role == .run ? .scopedCoding : .readOnlyEvidence }

    /// What the built-in adapter for `provider` can do; nil for a provider no adapter exists for.
    static func capabilities(of provider: AgentProviderID, config: Config) -> AgentCapabilities? {
        switch provider {
        case .claude: ClaudeProvider(config: config).capabilities
        case .codex: CodexProvider().capabilities
        default: nil
        }
    }

    func activeGoal() -> DoctorGoal? {
        guard let id = store.activeThreadID(),
            let text = try? String(contentsOf: project.goalURL(id), encoding: .utf8),
            let goal = try? GoalFile.parse(text).goal
        else { return nil }
        return DoctorGoal(
            thread: id, spend: goal.spend, turnTimeoutMin: goal.turnTimeoutMin, model: goal.model,
            approvedFor: store.state(of: id).approvedFor)
    }

    /// Each responsibility's resolved provider and model with what is wrong or limited about it. Reads the adapters'
    /// capabilities, not a second list of what they can do. `capabilities` is replaced in tests.
    static func agents(
        _ config: Config, searchPath: String?, goal: DoctorGoal? = nil,
        capabilities: ((AgentProviderID) -> AgentCapabilities?)? = nil
    ) -> [DoctorAgent] {
        var found = [
            DoctorAgent(
                role: .goal, resolved: config.resolvedGoalAgent,
                note: config.resolvedGoalAgent == nil ? "goal drafting stays manual" : nil),
            DoctorAgent(role: .run, resolved: config.resolvedRunAgent(goalModel: goal?.model), note: nil),
            DoctorAgent(role: .judge, resolved: config.resolvedJudgeAgent(), note: nil),
            DoctorAgent(role: .review, resolved: config.resolvedReviewAgent(), note: nil),
        ]
        for index in found.indices {
            guard let resolved = found[index].resolved else { continue }
            found[index].issues = issues(
                role: found[index].role, resolved: resolved, config: config, searchPath: searchPath, goal: goal,
                caps: capabilities?(resolved.provider) ?? Self.capabilities(of: resolved.provider, config: config))
        }
        // Each listed stage resolves on its own: one that moves to a provider without a dollar cap needs its own opt-in.
        if let at = found.firstIndex(where: { $0.role == .review }) {
            for name in config.review.stages where name != ReviewConfig.prReviewStage && config.review.stage(name) != nil {
                let agent = config.resolvedReviewAgent(stage: name)
                guard let caps = capabilities?(agent.provider) ?? Self.capabilities(of: agent.provider, config: config),
                    caps.policies.contains(.readOnlyEvidence)
                else { continue }
                let spend = AgentSpendPolicy.spend(
                    role: .review, agent: agent, capabilities: caps, cap: 0,
                    legacy: config.reviewUsesLegacySelection(stage: name),
                    table: config.allowUnpricedTable(.review, stage: name))
                if case .failure(let refusal) = spend {
                    found[at].issues.append(
                        DoctorAgentIssue(
                            role: .review, kind: "unpriced_not_allowed", severity: .problem,
                            message: "review stage \(name) is refused on \(agent.provider): \(refusal.message)"))
                }
            }
        }
        let used = Set(found.compactMap { $0.resolved?.provider })
        let unusedProviders = config.agents.executables.keys.filter { !used.contains($0) }.sorted { "\($0)" < "\($1)" }
        for provider in unusedProviders {
            found[found.count - 1].issues.append(
                DoctorAgentIssue(
                    role: .review, kind: "setting_unused", severity: .note,
                    message: "[providers.\(provider)] executable is not used: no responsibility resolves to \(provider)"
                ))
        }
        return found
    }

    private static func issues(
        role: AgentRole, resolved: ResolvedAgent, config: Config, searchPath: String?,
        goal: DoctorGoal?, caps: AgentCapabilities?
    ) -> [DoctorAgentIssue] {
        var out: [DoctorAgentIssue] = []
        func add(_ kind: String, _ severity: DoctorAgentIssue.Severity, _ message: String) {
            out.append(DoctorAgentIssue(role: role, kind: kind, severity: severity, message: message))
        }
        let provider = resolved.provider
        let executable = config.executable(for: provider)
        if ExecutableResolver.resolve(executable, searchPath: searchPath) == nil {
            add(
                "missing_executable", .problem,
                "\(provider) is not installed or not on PATH (looked for `\(executable)`)")
        }
        guard let caps else {
            add(
                "policy_without_controls", .problem,
                "there is no adapter for \(provider); \(role.rawValue) cannot use it")
            return out
        }
        let policy = policy(for: role)
        if !caps.policies.contains(policy) {
            add(
                "policy_without_controls", .problem,
                "\(provider) has no verified controls for \(policy.rawValue); \(role.rawValue) is refused on it")
        }
        if role == .run, let goal, case .hardCap(let budget) = goal.spend, !caps.hardDollarCap {
            add(
                "budget_without_cap", .problem,
                "goal \(goal.thread) has budget_usd $\(budget) and \(provider) cannot enforce a dollar limit; "
                    + "run is refused on it. Change the goal to `spend_policy: timeout_only` (and remove budget_usd), "
                    + "then approve it again")
        }
        if role != .run, caps.policies.contains(.readOnlyEvidence), !caps.confinesReads {
            add(
                "unconfined_reads", .note,
                "a read-only \(role.rawValue) on \(provider) can read files outside the checkout; "
                    + "repository writes and posting are still refused")
        }
        // A judge or review on a provider with no dollar cap needs the opt-in, the same rule the commands apply.
        if role != .run, caps.policies.contains(.readOnlyEvidence) {
            let legacy = role == .review && config.reviewUsesLegacySelection()
            let spend = AgentSpendPolicy.spend(
                role: role, agent: resolved, capabilities: caps, cap: 0, legacy: legacy, table: config.allowUnpricedTable(role))
            if case .failure(let refusal) = spend {
                let job = role == .goal ? "goal draft" : role.rawValue
                add("unpriced_not_allowed", .problem, "\(job) is refused on \(provider): \(refusal.message)")
            }
        }
        let selection = config.agents.selection(role)
        if selection.allowUnpriced != nil {
            add(
                "setting_unused", .note,
                caps.hardDollarCap
                    ? "[agents.\(role.rawValue)] allow_unpriced has no effect: \(provider) enforces a dollar limit"
                    : "[agents.\(role.rawValue)] allow_unpriced = \(selection.allowUnpriced == true) "
                        + (selection.allowUnpriced == true
                            ? "lets the \(role.rawValue) run on \(provider) with only a timeout; its cost is unknown"
                            : "keeps the \(role.rawValue) on \(provider) refused: it has no dollar cap"))
        }
        return out
    }
}
