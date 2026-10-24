import Foundation

/// The provider and model one responsibility last used, read from the log. A thread from before provider selection
/// has no such records, so it reads as what it was then (`recorded` false) and never as blank.
public struct AgentUse: Sendable, Equatable {
    public var provider: String
    /// Nil is the provider's own default.
    public var model: String?
    /// False when no record named the provider and this is the pre-P9 default for the responsibility.
    public var recorded: Bool
    public var stage: String?
    public var turn: Int
    public var round: Int?
    /// The `agent.attempt.started` id this was read from, nil when only a start record or a legacy default says it.
    public var attempt: String?
    /// False for an attempt that was refused before anything was started.
    public var spawned: Bool
    /// The attempt's `outcome` once it ended; nil while open or when no attempt was recorded.
    public var outcome: String?

    public init(
        provider: String, model: String?, recorded: Bool, stage: String? = nil, turn: Int = 0, round: Int? = nil,
        attempt: String? = nil, spawned: Bool = true, outcome: String? = nil
    ) {
        self.provider = provider
        self.model = model
        self.recorded = recorded
        self.stage = stage
        self.turn = turn
        self.round = round
        self.attempt = attempt
        self.spawned = spawned
        self.outcome = outcome
    }

    /// `claude, model opus`: the one wording `status`, `review` and `doctor` share.
    public static func describe(provider: String, model: String?) -> String {
        "\(provider), model \(model ?? "the provider's default")"
    }

    public var description: String {
        var text = Self.describe(provider: provider, model: model)
        if let stage { text += ", stage \(stage)" }
        if !spawned { text += " (refused: nothing was started)" } else if let outcome { text += " (\(outcome))" }
        if !recorded { text += " (not recorded: from before providers were chosen)" }
        return text
    }

    /// What a responsibility was before `[agents]`: Claude coded and judged, Codex reviewed.
    static func legacy(role: String, turn: Int, round: Int? = nil) -> AgentUse {
        AgentUse(provider: role == "review" ? "codex" : "claude", model: nil, recorded: false, turn: turn, round: round)
    }

    /// From a record that carries `provider` and `model` (`turn.started`, `judge.started`, `pr_review.started`), else
    /// the legacy default.
    init(start event: Event, role: String) {
        let round = event.data["round"]?.intValue
        if let provider = event.data["provider"]?.stringValue {
            self.init(
                provider: provider, model: event.data["model"]?.stringValue, recorded: true,
                stage: event.data["stage"]?.stringValue, turn: event.turn, round: round)
        } else {
            self = Self.legacy(role: role, turn: event.turn, round: round)
            stage = event.data["stage"]?.stringValue
        }
    }

    init?(attempt event: Event) {
        guard let provider = event.data["provider"]?.stringValue else { return nil }
        self.init(
            provider: provider, model: event.data["model"]?.stringValue, recorded: true,
            stage: event.data["stage"]?.stringValue, turn: event.turn, round: event.data["round"]?.intValue,
            attempt: event.data["attempt"]?.stringValue, spawned: event.data["spawned"] != false)
    }
}

extension ThreadState {
    /// What the goal was approved for, and whether an approval said so. Nil when nothing was approved. An approval
    /// from before provider selection binds nothing and reads as Claude's default, `recorded` false.
    public var approvedFor: AgentUse? {
        guard approvedGoalHash != nil else { return nil }
        guard let agent = approvedAgent else { return AgentUse(provider: "claude", model: nil, recorded: false) }
        return AgentUse(provider: agent.provider, model: agent.model, recorded: true)
    }

    /// `approved for:` and one `agent <role>:` line for each responsibility that ran, as `status` and `review` show
    /// them. Empty for a thread that has neither.
    public func agentLines() -> [String] {
        func label(_ text: String) -> String { text.padding(toLength: 14, withPad: " ", startingAt: 0) }
        var lines: [String] = []
        if let approved = approvedFor { lines.append(label("approved for:") + approved.description) }
        for role in ["run", "judge", "review"] {
            if let use = agentUse[role] { lines.append(label("agent \(role):") + use.description) }
        }
        return lines
    }

    /// Folds one record into `agentUse`. An attempt record wins over the start record of the same turn and round,
    /// which carries the same provider and model.
    static func applyAgent(_ event: Event, to uses: inout [String: AgentUse]) {
        func start(_ role: String) {
            let use = AgentUse(start: event, role: role)
            if let known = uses[role], known.attempt != nil, known.turn == use.turn, known.round == use.round { return }
            uses[role] = use
        }
        switch event.kind {
        case .turnStarted: start("run")
        case .judgeStarted: start("judge")
        case .prReviewStarted, .reviewStageStarted: start("review")
        case .agentAttemptStarted:
            guard let role = event.data["role"]?.stringValue, let use = AgentUse(attempt: event) else { return }
            uses[role] = use
        case .agentAttemptEnded:
            guard let role = event.data["role"]?.stringValue, uses[role]?.attempt == event.data["attempt"]?.stringValue,
                uses[role]?.attempt != nil
            else { return }
            uses[role]?.outcome = event.data["outcome"]?.stringValue
        default: break
        }
    }
}
