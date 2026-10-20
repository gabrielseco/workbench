/// What happened. An open set: readers ignore kinds they do not know (spec: event-log.md).
public struct EventKind: RawRepresentable, Hashable, Sendable, Codable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    public static let threadCreated: EventKind = "thread.created"
    public static let goalSaved: EventKind = "goal.saved"
    public static let goalApproved: EventKind = "goal.approved"
    public static let turnStarted: EventKind = "turn.started"
    public static let claude: EventKind = "claude"
    public static let turnEnded: EventKind = "turn.ended"
    public static let checkStarted: EventKind = "check.started"
    public static let checkRan: EventKind = "check.ran"
    public static let setupRan: EventKind = "setup.ran"
    public static let verifyStarted: EventKind = "verify.started"
    public static let verifyEnded: EventKind = "verify.ended"
    public static let threadNote: EventKind = "thread.note"
    public static let grantAdded: EventKind = "grant.added"
    public static let reviewDecision: EventKind = "review.decision"
    public static let abandonSaved: EventKind = "abandon.saved"
    public static let worktreeCreated: EventKind = "worktree.created"
    public static let proofAdded: EventKind = "proof.added"
    public static let proofPublished: EventKind = "proof.published"
    public static let judgeStarted: EventKind = "judge.started"
    public static let judgeRan: EventKind = "judge.ran"
    public static let verifierStarted: EventKind = "verifier.started"
    public static let verifierEnded: EventKind = "verifier.ended"
    public static let runStarted: EventKind = "run.started"
    public static let runEnded: EventKind = "run.ended"
    public static let verifierSkipped: EventKind = "verifier.skipped"
    public static let planStarted: EventKind = "plan.started"
    public static let planEnded: EventKind = "plan.ended"
    public static let planEdited: EventKind = "plan.edited"
    public static let prReviewStarted: EventKind = "pr_review.started"
    public static let prReviewFinished: EventKind = "pr_review.finished"
    public static let reviewStageStarted: EventKind = "review_stage.started"
    public static let reviewStageFinished: EventKind = "review_stage.finished"
    public static let prOpened: EventKind = "pr.opened"
    public static let prDescribed: EventKind = "pr.described"
    public static let prRefreshed: EventKind = "pr.refreshed"
    public static let worktreeRemoved: EventKind = "worktree.removed"
    public static let branchRemoved: EventKind = "branch.removed"
    public static let branchAhead: EventKind = "branch.ahead"
}

/// One line of `events.jsonl`.
public struct Event: Sendable, Equatable, Codable {
    public static let currentVersion = 1

    public var v: Int
    public var seq: Int
    public var ts: String
    public var turn: Int
    public var kind: EventKind
    public var data: JSONValue

    public init(v: Int = Event.currentVersion, seq: Int, ts: String, turn: Int, kind: EventKind, data: JSONValue) {
        self.v = v
        self.seq = seq
        self.ts = ts
        self.turn = turn
        self.kind = kind
        self.data = data
    }
}
