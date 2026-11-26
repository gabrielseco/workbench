import Foundation

/// What each agent role of a project is set to, read from its config for a person to look at (the app's Agents card, the
/// agent named on a chat). It reads the same resolvers a run uses, so what it shows is what would run. It never writes.
public struct AgentSetup: Sendable, Equatable {
    /// The roles in the order they are shown: the ones a thread meets first, the verifier last.
    public enum Role: String, Sendable, CaseIterable, Identifiable {
        case goal, plan, run, judge, review, ship, verifier
        public var id: String { rawValue }

        public var summary: String {
            switch self {
            case .goal: "Chat, and drafting a goal"
            case .plan: "The plan before a run"
            case .run: "The coding turns"
            case .judge: "Judges a finished turn"
            case .review: "Reviews the pull request"
            case .ship: "Writes the pull request"
            case .verifier: "Drives the app to check it"
            }
        }
    }

    /// Where a row's provider and model came from.
    public enum Source: Sendable, Equatable {
        /// The config's `[agents.<role>]` table (or `[verifier] model`, or the pr-review stage) names something.
        case configured
        /// The config names nothing, so the provider's own default runs.
        case providerDefault
        /// Nothing runs: no `[agents.goal]`, or the verifier is turned off (`[verifier] enabled = false`).
        case off
    }

    public struct Row: Sendable, Equatable, Identifiable {
        public var role: Role
        public var provider: AgentProviderID?
        /// Nil is the provider's own model.
        public var model: String?
        public var reasoningEffort: String?
        public var source: Source
        /// The table that decides this role instead of its `[agents.<role>]` one, so editing that one would change nothing: the pr-review stage.
        public var lockedBy: String?
        /// The keys of this role that table decides (a stage may set only an effort): only those are locked, the others still edit.
        public var lockedFields: Set<ConfigEdit.Field> = []
        /// The models this role's provider offers in a menu (`AgentSetup.modelOptions`); empty when the role is off.
        public var modelOptions: [String] = []
        /// The providers this role can be set to (`AgentSetup.providers(for:config:)`).
        public var providerOptions: [AgentProviderID] = []
        public var id: String { role.id }

        /// "Codex · gpt-6.1-terra", "Claude · default model", or nil when the role is off.
        public var label: String? {
            guard let provider else { return nil }
            return "\(AgentSetup.name(provider)) · \(model ?? "default model")"
        }
    }

    public var rows: [Row]

    public func row(_ role: Role) -> Row? { rows.first { $0.role == role } }

    /// "Codex" for a provider id, as a person says it.
    public static func name(_ provider: AgentProviderID) -> String {
        provider == .opencode ? "OpenCode" : provider.rawValue.prefix(1).uppercased() + provider.rawValue.dropFirst()
    }

    public init(config: Config) {
        var rows = Role.allCases.map { Self.row($0, config) }
        let used = Self.usedModels(rows, config)
        for index in rows.indices {
            rows[index].providerOptions = Self.providers(for: rows[index].role, config: config)
            guard let provider = rows[index].provider else { continue }
            rows[index].modelOptions = Self.modelOptions(provider: provider, config: config, used: used[provider] ?? [])
        }
        self.rows = rows
    }

    /// A provider's menu: the catalog's names, then the project's `[providers.<id>] models`, then the models its roles already use, without
    /// repeats and in that order, so a name a project set never drops out of its own menu.
    static func modelOptions(provider: AgentProviderID, config: Config, used: [String]) -> [String] {
        var seen = Set<String>()
        let all = ModelCatalog.names(for: provider) + (config.agents.models[provider] ?? []) + used
        return all.filter { seen.insert($0).inserted }
    }

    /// The models set on a role of each provider, in the order the roles are shown (every pr-review stage included).
    private static func usedModels(_ rows: [Row], _ config: Config) -> [AgentProviderID: [String]] {
        var used: [AgentProviderID: [String]] = [:]
        func add(_ provider: AgentProviderID?, _ model: String?) {
            if let provider, let model { used[provider, default: []].append(model) }
        }
        for row in rows { add(row.provider, row.model) }
        for name in config.review.definitions.keys.sorted() {
            let stage = config.resolvedReviewAgent(stage: name)
            add(stage.provider, stage.model)
        }
        return used
    }

    private static func isSet(_ selection: AgentSelection) -> Bool {
        selection.provider != nil || selection.model != nil || selection.reasoningEffort != nil
    }

    private static func row(_ role: Role, _ config: Config) -> Row {
        func make(_ agent: ResolvedAgent, _ selection: AgentSelection, also stageSet: Bool = false) -> Row {
            Row(
                role: role, provider: agent.provider, model: agent.model, reasoningEffort: agent.reasoningEffort,
                source: isSet(selection) || stageSet ? .configured : .providerDefault)
        }
        func off() -> Row { Row(role: role, provider: nil, model: nil, reasoningEffort: nil, source: .off) }
        switch role {
        case .goal:
            guard let agent = config.resolvedGoalAgent else { return off() }
            return make(agent, config.agents.goal ?? AgentSelection())
        case .plan: return make(config.resolvedPlanAgent(), config.agents.plan)
        case .run: return make(config.resolvedRunAgent(), config.agents.run)
        case .judge: return make(config.resolvedJudgeAgent(), config.agents.judge)
        case .review:
            // The pull-request review also reads `[review.stage.pr-review]`, which can name its own provider, model or effort.
            let stage = config.review.stage(ReviewConfig.prReviewStage)
            var locked: Set<ConfigEdit.Field> = []
            if stage?.provider != nil { locked.insert(.provider) }
            if stage?.model != nil { locked.insert(.model) }
            if stage?.reasoningEffort != nil { locked.insert(.reasoningEffort) }
            var row = make(config.resolvedReviewAgent(), config.agents.review, also: !locked.isEmpty)
            if !locked.isEmpty { (row.lockedBy, row.lockedFields) = ("[review.stage.\(ReviewConfig.prReviewStage)]", locked) }
            return row
        case .ship: return make(config.resolvedShipAgent, config.agents.ship)
        case .verifier:
            // On unless `[verifier] enabled = false`; Claude unless `[verifier] provider` names another. It has no effort to set.
            guard let verifier = config.verifier else { return off() }
            var row = Row(
                role: role, provider: verifier.resolvedProvider, model: verifier.model, reasoningEffort: nil,
                source: verifier.provider == nil && verifier.model == nil ? .providerDefault : .configured)
            row.lockedFields = [.reasoningEffort]
            return row
        }
    }

    /// What a chat will talk to, or nil when the project has no goal agent and a chat is refused.
    public static func chatAgent(_ config: Config?) -> String? {
        config.flatMap { AgentSetup(config: $0).row(.goal)?.label }
    }

    public static func chatAgent(for setup: AgentSetup) -> String? { setup.row(.goal)?.label }

    /// The efforts `reasoning_effort` takes, for a picker. OpenCode takes none.
    public static let efforts = AgentsConfig.efforts

    /// The providers `role` can be set to in a project with `config`: Claude and Codex, and OpenCode when the project names its
    /// gateway (`[providers.opencode]`) and the role runs on it. The verifier does not.
    public static func providers(for role: Role, config: Config) -> [AgentProviderID] {
        let always: [AgentProviderID] = [.claude, .codex]
        guard config.agents.opencode != nil, let agentRole = AgentRole(rawValue: role.rawValue),
            agentRole.supportedProviders.contains(.opencode)
        else { return always }
        return always + [.opencode]
    }

    /// Who a project with no goal agent can pick to draft at once. OpenCode only where `[providers.opencode] models` lists one:
    /// picking it writes that model, and without one the draft it starts would be refused and the choice already made.
    public static func draftChoices(config: Config) -> [AgentProviderID] {
        let hasModel = config.agents.models[.opencode]?.isEmpty == false
        return providers(for: .goal, config: config).filter { $0 != .opencode || hasModel }
    }

    /// The provider a model name looks like it belongs to, when that is not `provider`: `opus` on Codex is a Claude name, `gpt-6.1` on
    /// Claude is an OpenAI one. A name that looks like neither is no mismatch: only a name it knows is flagged.
    public static func modelFit(provider: AgentProviderID, model: String) -> AgentProviderID? {
        let name = model.lowercased()
        // A gateway names its models as it likes (`claude-sonnet-5`, `gpt-6-sol`); only Claude Code's own aliases cannot be one.
        if provider == .opencode { return ["opus", "sonnet", "haiku"].contains(name) ? .claude : nil }
        let claude = ["opus", "sonnet", "haiku"].contains { name == $0 || name.hasPrefix($0 + "[") } || name.hasPrefix("claude-")
        let openAI = name.hasPrefix("gpt-") || name.range(of: #"^o[0-9]"#, options: .regularExpression) != nil
        if claude, provider != .claude { return .claude }
        if openAI, provider != .codex { return .codex }
        return nil
    }

    /// Said after the run agent is changed while a coding thread is active: `run` refuses a goal approved for other coding settings.
    public static func runChangeNote(in project: Project) -> String? {
        let store = ThreadStore(project: project)
        let coding = store.activeThreadIDs().filter { !store.state(of: $0).isChat }
        guard !coding.isEmpty else { return nil }
        let active = coding.count == 1 ? "thread \(coding[0])" : "threads \(coding.joined(separator: ", "))"
        return "\(active) may have been approved for the old run settings: `workbench run` refuses until "
            + "`workbench goal approve` binds the new ones"
    }
}
