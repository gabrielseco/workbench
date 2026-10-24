import Foundation

/// How an evaluation (judge, review) is bounded, decided before anything is spawned. A provider with a hard dollar
/// cap gets one; one without runs on its timeout alone, but only when the config says so (`allow_unpriced`) or the
/// thread is on the legacy Codex review, which has always run that way (docs/plan/P9-agent-providers.md,
/// "Capabilities and permission policy"). A refusal names the key that would allow it.
enum AgentSpendPolicy {
    /// - Parameters:
    ///   - cap: the dollar cap used when the provider can enforce one.
    ///   - legacy: the compatibility exception; never true for the judge.
    ///   - table: where `allow_unpriced` would be set, as the config writes it.
    static func spend(
        role: AgentRole, agent: ResolvedAgent, capabilities: AgentCapabilities, cap: Decimal, legacy: Bool, table: String
    ) -> Result<AgentSpend, AgentFailure> {
        if capabilities.hardDollarCap { return .success(.hardCap(cap)) }
        if agent.allowUnpriced || legacy { return .success(.timeoutOnly) }
        let job = role == .goal ? "goal draft" : role.rawValue
        return .failure(
            AgentFailure(
                .unsupportedCapability,
                "\(agent.provider) cannot enforce a dollar limit, so the \(job) on it has no cap and its cost is "
                    + "unknown. Set allow_unpriced = true in \(table) to accept a timeout-only \(job), "
                    + "or choose another provider.",
                retry: .afterFix))
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
