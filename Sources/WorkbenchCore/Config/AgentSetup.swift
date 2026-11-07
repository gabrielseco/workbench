import Foundation

/// What each agent role of a project is set to, read from its config for a person to look at (the app's Agents card, the
/// agent named on a chat). It reads the same resolvers a run uses, so what it shows is what would run. It never writes.
public struct AgentSetup: Sendable, Equatable {
    /// The roles in the order they are shown: the ones a thread meets first, the verifier last.
    public enum Role: String, Sendable, CaseIterable, Identifiable {
        case goal, plan, run, judge, review, ship, verifier
        public var id: String { rawValue }

        /// What the role does, in a few words.
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
        provider.rawValue.prefix(1).uppercased() + provider.rawValue.dropFirst()
    }

    public init(config: Config) {
        rows = Role.allCases.map { Self.row($0, config) }
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
            // The verifier is Claude only, and on unless `[verifier] enabled = false`.
            guard config.verifier != nil else { return off() }
            return Row(
                role: role, provider: .claude, model: config.verifierModel, reasoningEffort: nil,
                source: config.verifierModel == nil ? .providerDefault : .configured)
        }
    }

    /// What a chat will talk to, or nil when the project has no goal agent and a chat is refused.
    public static func chatAgent(_ config: Config?) -> String? {
        config.flatMap { AgentSetup(config: $0).row(.goal)?.label }
    }

    public static func chatAgent(for setup: AgentSetup) -> String? { setup.row(.goal)?.label }

    /// The providers a role can be set to, and the efforts `reasoning_effort` takes, for a picker.
    public static let providers: [AgentProviderID] = [.claude, .codex]
    public static let efforts = AgentsConfig.efforts

    /// The provider a model name looks like it belongs to, when that is not `provider`: `opus` on Codex is a Claude name, `gpt-6.1` on
    /// Claude is an OpenAI one. A name that looks like neither is no mismatch: only a name it knows is flagged.
    public static func modelFit(provider: AgentProviderID, model: String) -> AgentProviderID? {
        let name = model.lowercased()
        let claude = ["opus", "sonnet", "haiku"].contains { name == $0 || name.hasPrefix($0 + "[") } || name.hasPrefix("claude-")
        let openAI = name.hasPrefix("gpt-") || name.range(of: #"^o[0-9]"#, options: .regularExpression) != nil
        if claude, provider != .claude { return .claude }
        if openAI, provider != .codex { return .codex }
        return nil
    }

    /// Said after the run agent is changed while a coding thread is active: `run` refuses a goal approved for other coding settings.
    public static func runChangeNote(in project: Project) -> String? {
        let store = ThreadStore(project: project)
        guard let active = store.activeThreadID(), !store.state(of: active).isChat else { return nil }
        return "thread \(active) may have been approved for the old run settings: `workbench run` refuses until "
            + "`workbench goal approve` binds the new ones"
    }
}
