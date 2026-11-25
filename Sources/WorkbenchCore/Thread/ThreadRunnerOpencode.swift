import Foundation

extension ThreadRunner {
    /// Everything that is checked about the coding provider before a worktree or a turn exists.
    static func requireCodingProviderReady(agent: ResolvedAgent, goal: Goal, config: Config, options: RunOptions) throws {
        try requireProviderCanCode(agent: agent, goal: goal, options: options)
        try requireCodingGateway(agent: agent, config: config, options: options)
    }

    /// Refuses, before a worktree or a turn exists, an OpenCode run that could not reach its gateway: no `[providers.opencode]`, no key
    /// in the environment, or a key too short to be kept out of an answer that echoes it.
    static func requireCodingGateway(agent: ResolvedAgent, config: Config, options: RunOptions) throws {
        guard agent.provider == .opencode else { return }
        guard let gateway = config.agents.opencode else {
            throw RunnerError.codingUnsupported("opencode needs [providers.opencode] with a base_url")
        }
        let key = options.parentEnvironment[gateway.apiKeyVariable] ?? ""
        guard !key.isEmpty else {
            throw RunnerError.codingUnsupported(
                "opencode reads its gateway key from $\(gateway.apiKeyVariable), which is not set")
        }
        guard key.utf8.count >= ForwardPolicy.minimumKeyLength else {
            let length = ForwardPolicy.minimumKeyLength
            throw RunnerError.codingUnsupported(
                "the gateway key in $\(gateway.apiKeyVariable) is shorter than \(length) characters, so it could "
                    + "not be kept out of an answer that echoes it; use a longer key")
        }
    }

    /// The adapter for this turn's coding agent, and what must be stopped when the turn ends. An OpenCode turn runs in a sandbox that can
    /// reach only loopback, so its model traffic goes through a `LoopbackForwarder` that holds the real key; the forwarder lives exactly
    /// as long as the turn, and the caller stops it on every way out (`defer`), whether the turn finished, failed, timed out or was
    /// stopped.
    func makeCodingProvider(
        agent: ResolvedAgent, config: Config, options: RunOptions
    ) throws -> (provider: any AgentProvider, forwarder: LoopbackForwarder?) {
        switch agent.provider {
        case .codex:
            return (CodexProvider(executable: config.executable(for: .codex)), nil)
        case .opencode:
            guard let gateway = config.agents.opencode, let upstream = URL(string: gateway.baseURL) else {
                throw RunnerError.codingUnsupported("opencode needs [providers.opencode] with a base_url")
            }
            guard let key = options.parentEnvironment[gateway.apiKeyVariable], !key.isEmpty else {
                let name = gateway.apiKeyVariable
                throw RunnerError.codingUnsupported("opencode reads its gateway key from $\(name), which is not set")
            }
            let forwarder: LoopbackForwarder
            let base: URL
            do {
                forwarder = try LoopbackForwarder(LoopbackForwarder.Configuration(upstream: upstream, apiKey: key))
                base = try forwarder.start()
            } catch {
                throw RunnerError.codingUnsupported("the gateway forwarder could not start: \(error)")
            }
            let provider = OpencodeProvider(
                executable: config.executable(for: .opencode), gateway: gateway,
                forwarder: OpencodeProvider.Forwarder(baseURL: base.absoluteString))
            return (provider, forwarder)
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
