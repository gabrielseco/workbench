import Foundation

extension ThreadRunner {
    /// Everything that is checked about the coding provider before a worktree or a turn exists.
    static func requireCodingProviderReady(agent: ResolvedAgent, goal: Goal, config: Config, options: RunOptions) throws {
        try requireProviderCanCode(agent: agent, goal: goal, options: options)
        try requireCodingGateway(agent: agent, config: config, options: options)
    }

    /// Refuses, before a worktree or a turn exists, an OpenCode run that could not reach its gateway: no `[providers.opencode]`, no key in
    /// the environment, or a key too short to be kept out of an answer that echoes it.
    static func requireCodingGateway(agent: ResolvedAgent, config: Config, options: RunOptions) throws {
        guard agent.provider == .opencode else { return }
        do {
            _ = try OpencodeGatewaySession.gateway(config: config, environment: options.parentEnvironment)
        } catch { throw RunnerError.codingUnsupported("\(error)") }
    }

    /// The adapter for this turn's coding agent, and the OpenCode session that must be stopped when the turn ends. An OpenCode turn runs
    /// in a sandbox that can reach only loopback, so its model traffic goes through a forwarder that holds the real key; the caller stops
    /// the session on every way out (`defer`), whether the turn finished, failed, timed out or was stopped.
    func makeCodingProvider(
        agent: ResolvedAgent, config: Config, options: RunOptions
    ) throws -> (provider: any AgentProvider, session: OpencodeGatewaySession?) {
        switch agent.provider {
        case .codex:
            return (CodexProvider(executable: config.executable(for: .codex)), nil)
        case .opencode:
            do {
                let session = try OpencodeGatewaySession.start(config: config, environment: options.parentEnvironment)
                return (session.provider, session)
            } catch { throw RunnerError.codingUnsupported("\(error)") }
        default:
            return (ClaudeProvider(config: config), nil)
        }
    }
}

extension AgentInvocation {
    /// What the log names as the program that started: the executable the adapter built, when it is a path (OpenCode starts under
    /// `sandbox-exec`), else the one the runner resolved.
    func shown(orResolved resolved: URL) -> String { executable.hasPrefix("/") ? executable : resolved.path }
}
