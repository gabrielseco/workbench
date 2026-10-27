import Foundation

/// The four things an agent does for a thread (docs/plan/P9-agent-providers.md). Each picks its own provider and model.
public enum AgentRole: String, Sendable, Equatable, CaseIterable {
    case goal
    case run
    case judge
    case review

    /// The providers an adapter exists for, in the order messages list them. A config that names another pair is
    /// refused when it loads, not ignored.
    public var supportedProviders: [AgentProviderID] { [.claude, .codex] }

    /// What the thread did before `[agents]` existed, used when the config names nothing.
    public var defaultProvider: AgentProviderID { self == .review ? .codex : .claude }
}

/// One `[agents.<role>]` table, or the `provider`, `model` and `allow_unpriced` keys of a review stage.
public struct AgentSelection: Sendable, Equatable {
    public var provider: AgentProviderID?
    public var model: String?
    /// `low` … `max`; nil is the provider's own setting (for Codex, whatever `~/.codex/config.toml` says).
    public var reasoningEffort: String?
    /// Timeout-only spending is accepted for this evaluation. Nil means the table did not say.
    public var allowUnpriced: Bool?

    public init(
        provider: AgentProviderID? = nil, model: String? = nil, reasoningEffort: String? = nil, allowUnpriced: Bool? = nil
    ) {
        self.provider = provider
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.allowUnpriced = allowUnpriced
    }

    /// The table chose a provider or a model, which is what makes it replace the legacy `model` keys.
    public var isSet: Bool { provider != nil || model != nil }
}

/// A role's provider, model and spending policy after every rule has been applied. Nothing reads it yet: the run,
/// judge and review paths still take their own settings (PR 8 and 9 move them over).
public struct ResolvedAgent: Sendable, Equatable {
    public var provider: AgentProviderID
    /// Nil is the provider's own default.
    public var model: String?
    public var reasoningEffort: String?
    /// The config said `allow_unpriced = true`.
    public var allowUnpriced: Bool
    /// The config said `allow_unpriced = false`: the one way an evaluation on a provider with no dollar cap is refused.
    public var forbidsUnpriced: Bool

    public init(
        provider: AgentProviderID, model: String?, reasoningEffort: String? = nil, allowUnpriced: Bool,
        forbidsUnpriced: Bool = false
    ) {
        self.provider = provider
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.allowUnpriced = allowUnpriced
        self.forbidsUnpriced = forbidsUnpriced
    }

    init(provider: AgentProviderID, model: String?, reasoningEffort: String?, unpriced: Bool?) {
        self.init(
            provider: provider, model: model, reasoningEffort: reasoningEffort, allowUnpriced: unpriced == true,
            forbidsUnpriced: unpriced == false)
    }
}

/// `[providers.<id>]` and `[agents.<role>]`.
public struct AgentsConfig: Sendable, Equatable {
    public var executables: [AgentProviderID: String] = [:]
    public var goal: AgentSelection?
    public var run = AgentSelection()
    public var judge = AgentSelection()
    public var review = AgentSelection()

    public init() {}

    public func selection(_ role: AgentRole) -> AgentSelection {
        switch role {
        case .goal: goal ?? AgentSelection()
        case .run: run
        case .judge: judge
        case .review: review
        }
    }

    static let providerPrefix = "providers."
    static let agentPrefix = "agents."
    static let providerKeys: Set<String> = ["executable"]
    static let selectionKeys: Set<String> = ["provider", "model", "reasoning_effort", "allow_unpriced"]
    /// Providers that can be named at all, whatever role they are named for.
    static let knownProviders: [AgentProviderID] = [.claude, .codex]

    static func owns(table name: String) -> Bool {
        name.hasPrefix(providerPrefix) || name.hasPrefix(agentPrefix)
    }

    /// The claude executable `[providers.claude]` names. `claude_path` names the same thing, so both is a conflict
    /// (reported at `claude_path`'s line); nil when the table names none or the conflict was reported.
    func claudeExecutable(claudePathLine: Int?, fail: ReviewConfig.Fail) -> String? {
        guard let executable = executables[.claude] else { return nil }
        guard let line = claudePathLine else { return executable }
        fail(.conflict, line, "'claude_path' and [providers.claude] 'executable' both name the claude executable; keep one")
        return nil
    }

    /// What `reasoning_effort` may be: the levels both `claude --effort` and Codex list. Which of them a model supports is its own check.
    static let efforts = ["low", "medium", "high", "xhigh", "max"]

    static func list(_ ids: [AgentProviderID]) -> String {
        ids.map { "\"\($0)\"" }.joined(separator: " or ")
    }

    static func list(_ names: [String], joiner: String) -> String {
        names.map { "\"\($0)\"" }.joined(separator: joiner)
    }
}

// MARK: Parsing

extension AgentsConfig {
    static func parse(_ document: TOMLDocument, fail: ReviewConfig.Fail) -> AgentsConfig {
        var config = AgentsConfig()
        for (name, table) in document.tables.sorted(by: { $0.value.line < $1.value.line }) where owns(table: name) {
            if name.hasPrefix(providerPrefix) {
                parseProvider(String(name.dropFirst(providerPrefix.count)), table: table, into: &config, fail: fail)
            } else {
                parseAgent(String(name.dropFirst(agentPrefix.count)), table: table, into: &config, fail: fail)
            }
        }
        return config
    }

    private static func parseProvider(_ id: String, table: TOMLTable, into config: inout AgentsConfig, fail: ReviewConfig.Fail) {
        guard let provider = AgentProviderID(id), knownProviders.contains(provider) else {
            fail(.unknownTable, table.line, "unknown table [providers.\(id)]: the providers are \(list(knownProviders))")
            return
        }
        for (key, entry) in table.entries.sorted(by: { $0.key < $1.key }) where !providerKeys.contains(key) {
            fail(.unknownKey, entry.line, "unknown key '\(key)' in [providers.\(id)]")
        }
        guard let entry = table.entries["executable"] else { return }
        guard case .string(let value) = entry.value else {
            fail(.wrongType, entry.line, "'executable' must be a string, found \(entry.value.typeName)")
            return
        }
        if value.isEmpty || value.contains("\n") || value.contains("\0") {
            fail(.invalidValue, entry.line, "'executable' must be a command name or a path")
        } else {
            config.executables[provider] = value
        }
    }

    private static func parseAgent(_ name: String, table: TOMLTable, into config: inout AgentsConfig, fail: ReviewConfig.Fail) {
        guard let role = AgentRole(rawValue: name) else {
            let roles = AgentRole.allCases.map(\.rawValue).joined(separator: ", ")
            fail(.unknownTable, table.line, "unknown table [agents.\(name)]: the agents are \(roles)")
            return
        }
        let tableName = "agents.\(name)"
        for (key, entry) in table.entries.sorted(by: { $0.key < $1.key }) where !selectionKeys.contains(key) {
            fail(.unknownKey, entry.line, "unknown key '\(key)' in [\(tableName)]")
        }
        let selection = AgentSelection.parse(table, name: tableName, role: role, fail: fail)
        if role == .run, let entry = table.entries["allow_unpriced"] {
            fail(
                .invalidValue, entry.line,
                "'allow_unpriced' is not allowed in [agents.run]: spending without a dollar cap is approved in the goal")
        }
        if role == .goal, selection.provider == nil, table.entries["provider"] == nil {
            fail(.missingKey, table.line, "missing key 'provider' in [agents.goal]: drafting has no default provider")
        }
        switch role {
        case .goal: config.goal = selection
        case .run: config.run = selection
        case .judge: config.judge = selection
        case .review: config.review = selection
        }
    }
}

extension AgentSelection {
    /// `provider`, `model` and `allow_unpriced` of one table; a provider that has no adapter for `role` yet is a
    /// problem here, so no config is accepted that a later stage would have to ignore.
    /// `inheritsProvider`: a review stage table, whose missing `provider` comes from `[agents.review]` (checked once
    /// both are known, in `Config.load`).
    static func parse(
        _ table: TOMLTable, name: String, role: AgentRole, inheritsProvider: Bool = false, fail: ReviewConfig.Fail
    ) -> AgentSelection {
        var selection = AgentSelection()
        if let entry = table.entries["provider"] {
            if case .string(let value) = entry.value {
                selection.provider = provider(value, line: entry.line, role: role, table: name, fail: fail)
            } else {
                fail(.wrongType, entry.line, "'provider' must be a string, found \(entry.value.typeName)")
            }
        }
        if let entry = table.entries["model"] {
            if case .string(let value) = entry.value {
                if SafeNames.isModelName(value) {
                    selection.model = value
                } else {
                    fail(.invalidValue, entry.line, "'model' in [\(name)] must be a model name or alias like \"haiku\"")
                }
            } else {
                fail(.wrongType, entry.line, "'model' must be a string, found \(entry.value.typeName)")
            }
        }
        if let entry = table.entries["reasoning_effort"] {
            if case .string(let value) = entry.value {
                if AgentsConfig.efforts.contains(value) {
                    selection.reasoningEffort = value
                } else {
                    let levels = AgentsConfig.list(AgentsConfig.efforts, joiner: ", ")
                    fail(.invalidValue, entry.line, "'reasoning_effort' in [\(name)] must be one of \(levels)")
                }
            } else {
                fail(.wrongType, entry.line, "'reasoning_effort' must be a string, found \(entry.value.typeName)")
            }
        }
        if let entry = table.entries["allow_unpriced"] {
            if case .bool(let value) = entry.value {
                selection.allowUnpriced = value
            } else {
                fail(.wrongType, entry.line, "'allow_unpriced' must be true or false, found \(entry.value.typeName)")
            }
        }
        return selection
    }

    /// A provider id for `role`, or nil after `fail` has been told why not.
    static func provider(
        _ value: String, line: Int, role: AgentRole, table: String, fail: ReviewConfig.Fail
    ) -> AgentProviderID? {
        guard let id = AgentProviderID(value), AgentsConfig.knownProviders.contains(id) else {
            fail(.invalidValue, line, "'provider' must be \(AgentsConfig.list(AgentsConfig.knownProviders))")
            return nil
        }
        guard role.supportedProviders.contains(id) else {
            fail(
                .invalidValue, line,
                "[\(table)] cannot use \"\(id)\" yet: \(role.rawValue) runs on \(AgentsConfig.list(role.supportedProviders)) "
                    + "only until its second provider is enabled (docs/plan/P9-agent-providers.md, task 4)")
            return nil
        }
        return id
    }
}

// MARK: Resolution

extension Config {
    /// The executable for a provider: its `[providers.<id>]` override, else its name.
    public func executable(for provider: AgentProviderID) -> String {
        agents.executables[provider] ?? (provider == .claude ? claudePath : "\(provider)")
    }

    /// Drafting: only when `[agents.goal]` exists. It never inherits the coding `model`.
    public var resolvedGoalAgent: ResolvedAgent? {
        guard let goal = agents.goal, let provider = goal.provider else { return nil }
        return ResolvedAgent(
            provider: provider, model: goal.model, reasoningEffort: goal.reasoningEffort, unpriced: goal.allowUnpriced)
    }

    /// Coding: the goal's `model`, `[agents.run]`, the root `model`, then the provider's default. The root `model`
    /// is a Claude alias, so it is only used for Claude.
    public func resolvedRunAgent(goalModel: String? = nil) -> ResolvedAgent {
        let provider = agents.run.provider ?? AgentRole.run.defaultProvider
        let model = goalModel ?? agents.run.model ?? legacyModel(model, for: provider)
        return ResolvedAgent(
            provider: provider, model: model, reasoningEffort: agents.run.reasoningEffort, allowUnpriced: false)
    }

    /// The judge: `--model`, `[agents.judge]`, then the legacy `judge_model` and `model`, which apply only while
    /// `[agents.judge]` chooses nothing and only to Claude.
    public func resolvedJudgeAgent(modelFlag: String? = nil) -> ResolvedAgent {
        let provider = agents.judge.provider ?? AgentRole.judge.defaultProvider
        let legacy = agents.judge.isSet ? nil : legacyModel(judgeModel ?? model, for: provider)
        return ResolvedAgent(
            provider: provider, model: modelFlag ?? agents.judge.model ?? legacy,
            reasoningEffort: agents.judge.reasoningEffort, unpriced: agents.judge.allowUnpriced)
    }

    /// A review stage: its own table, then `[agents.review]`, then the provider's default. `allow_unpriced` is
    /// inherited from `[agents.review]` unless the stage sets it.
    public func resolvedReviewAgent(stage name: String = ReviewConfig.prReviewStage) -> ResolvedAgent {
        let stage = review.stage(name)
        let base = agents.review.provider ?? AgentRole.review.defaultProvider
        let provider = stage?.provider ?? base
        // A model names a provider's own model, so it is only inherited by a stage that keeps that provider.
        return ResolvedAgent(
            provider: provider, model: stage?.model ?? (provider == base ? agents.review.model : nil),
            reasoningEffort: stage?.reasoningEffort ?? (provider == base ? agents.review.reasoningEffort : nil),
            unpriced: stage?.allowUnpriced ?? agents.review.allowUnpriced)
    }

    /// True when the review provider is the one the thread always used (Codex) and no new `provider` key chose it: the
    /// P9 compatibility exception, which keeps its timeout-only policy even with `allow_unpriced = false`. `reviewer = "codex"`
    /// (P6) is not a new selection.
    public func reviewUsesLegacySelection(stage name: String = ReviewConfig.prReviewStage) -> Bool {
        if agents.review.provider != nil { return false }
        guard let stage = review.stage(name), stage.provider != nil else { return true }
        return stage.providerIsReviewerAlias
    }

    /// The table that holds `allow_unpriced` for `role`, as a config would write it.
    public func allowUnpricedTable(_ role: AgentRole, stage name: String = ReviewConfig.prReviewStage) -> String {
        guard role == .review, let stage = review.stage(name), stage.provider != nil, !stage.providerIsReviewerAlias,
            name != ReviewConfig.prReviewStage
        else { return "[agents.\(role.rawValue)]" }
        return "[agents.review] or [review.stage.\(name)]"
    }

    private func legacyModel(_ model: String?, for provider: AgentProviderID) -> String? {
        provider == .claude ? model : nil
    }
}
