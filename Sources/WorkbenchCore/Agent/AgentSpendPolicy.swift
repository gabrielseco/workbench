import Foundation

/// How an evaluation (judge, review) is bounded, decided before anything is spawned. A provider with a hard dollar
/// cap gets one; one without runs on its timeout alone, since choosing that provider is the consent, unless the config
/// forbids it with `allow_unpriced = false`. The legacy Codex review has always run timeout-only and still does
/// (docs/plan/P9-agent-providers.md, "Capabilities and permission policy"). A refusal names the key that forbade it.
enum AgentSpendPolicy {
    /// - Parameters:
    ///   - cap: the dollar cap used when the provider can enforce one.
    ///   - legacy: the compatibility exception; never true for the judge.
    ///   - table: where `allow_unpriced` is set, as the config writes it.
    static func spend(
        role: AgentRole, agent: ResolvedAgent, capabilities: AgentCapabilities, cap: Decimal, legacy: Bool, table: String
    ) -> Result<AgentSpend, AgentFailure> {
        if capabilities.hardDollarCap { return .success(.hardCap(cap)) }
        if !agent.forbidsUnpriced || legacy { return .success(.timeoutOnly) }
        let job = jobName(role)
        return .failure(
            AgentFailure(
                .unsupportedCapability,
                "\(agent.provider) cannot enforce a dollar limit, and allow_unpriced = false in \(table) forbids a "
                    + "timeout-only \(job). Remove that line to run the \(job) on \(agent.provider) bounded by its "
                    + "timeout, or choose another provider.",
                retry: .afterFix))
    }

    static func jobName(_ role: AgentRole) -> String {
        switch role {
        case .goal: "goal draft"
        case .ship: "PR description"
        default: role.rawValue
        }
    }
}

extension AgentRole {
    /// How long one evaluation may take; what bounds it on a provider with no dollar cap. Nil for coding, whose
    /// turn timeout is in the goal.
    var evaluationTimeout: TimeInterval? {
        switch self {
        case .goal: GoalDraft.timeout
        case .judge: Judge.timeout
        case .review: PRReview.timeout
        case .ship: PRDescriber.timeout
        case .plan: Plan.timeout
        case .run: nil
        }
    }
}

extension Config {
    /// The built-in adapter for `provider`, started from this config's executable for it.
    public func agentProvider(_ provider: AgentProviderID) -> (any AgentProvider)? {
        switch provider {
        case .claude: ClaudeProvider(config: self)
        case .codex: CodexProvider(executable: executable(for: .codex))
        default: nil
        }
    }
}
