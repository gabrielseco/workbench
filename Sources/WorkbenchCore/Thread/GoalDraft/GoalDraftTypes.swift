// What a goal draft is aimed at and what it gives back or is refused with.
import Foundation

/// Where a drafted goal goes: a new thread, or over the goal of an existing one (explicitly).
public enum GoalDraftTarget: Sendable, Equatable {
    case newThread(name: String, base: String?)
    case replace(id: String)
    /// The goal is drafted from a chat thread's conversation and written into that same thread (P22 slice 6b).
    case fromChat(id: String, base: String?)
    /// The goal is drafted from a Claude Code session of this project, rendered and bounded (`ClaudeSession`), into a new thread.
    case fromClaudeSession(name: String, base: String?, session: ClaudeSession.Rendered)
}

extension GoalDraftTarget {
    /// The thread an existing-thread draft works in; nil for a new one.
    var threadID: String? {
        switch self {
        case .replace(let id), .fromChat(let id, _): id
        case .newThread, .fromClaudeSession: nil
        }
    }

    /// The draft happens in a thread that already exists, so its folder is stable and a leftover is found by it.
    var draftsInPlace: Bool { threadID != nil }
}

/// What `workbench goal draft` came to. A draft that fails is a result, not a thrown error: it has already spent
/// what it spent, and nothing was written for it.
public struct GoalDraftResult: Sendable, Equatable {
    /// The thread written or rewritten; nil when the draft did not produce a goal.
    public var id: String?
    public var replaced: Bool
    /// The goal that was replaced had been approved, and now needs `goal approve` again.
    public var wasApproved: Bool
    public var proposal: GoalProposal?
    public var provider: AgentProviderID
    /// Nil is the provider's own default.
    public var model: String?
    public var costUSD: Double?
    public var failure: String?

    public init(
        id: String?, replaced: Bool = false, wasApproved: Bool = false, proposal: GoalProposal? = nil,
        provider: AgentProviderID, model: String? = nil, costUSD: Double? = nil, failure: String? = nil
    ) {
        (self.id, self.replaced, self.wasApproved, self.proposal) = (id, replaced, wasApproved, proposal)
        (self.provider, self.model, self.costUSD, self.failure) = (provider, model, costUSD, failure)
    }
}

/// Why a draft was not started. Nothing was spawned, spent, written or logged.
public enum GoalDraftRefusal: Error, Equatable, Sendable, CustomStringConvertible {
    case noGoalAgent
    case emptyRequest
    case requestTooLong
    case spend(String)
    case unavailable(String)
    case invalidName(String)
    case invalidBase(String)
    case activeThread(String)
    case doctorRunning
    case noThread(String)
    case goalUnreadable(String)
    case ended(String)
    case running(pid: Int32)
    case busy
    case imagesNeedANewThread
    case attachment(String)
    case notAChat(String)
    case chatHasGoal(String)
    case chatNotStarted(String)

    public var description: String {
        switch self {
        case .noGoalAgent:
            "goal drafting is off: no [agents.goal] names a provider. Write the goal by hand: "
                + "`workbench goal new <name>`, then fill in the file it prints."
        case .emptyRequest: "the request is empty: say what the goal should be about (--request or --request-file)."
        case .requestTooLong: "the request is over \(GoalDraft.requestLimit / 1024) KiB; shorten it."
        case .spend(let why), .unavailable(let why): why
        case .invalidName(let name): "'\(name)' is not a usable thread name: letters, digits, '.', '_' and '-' only."
        case .invalidBase(let base): "'\(base)' is not a safe branch name."
        case .activeThread(let id): "thread \(id) is still active: finish or abandon it first (one thread at a time)."
        case .doctorRunning: "`workbench doctor` is running; try again when it ends."
        case .noThread(let id): "no thread \(id)."
        case .goalUnreadable(let why): "the goal could not be read: \(why)"
        case .ended(let decision): "this thread has ended (\(decision)); its goal cannot be replaced."
        case .running(let pid): "a run is live on this thread (pid \(pid)); stop it first."
        case .notAChat(let id): "thread \(id) is not a chat: --from-chat drafts a goal from a conversation."
        case .chatHasGoal(let id):
            "chat \(id) has a goal already: redraft it with `workbench goal draft \(id) --replace --request \"...\"`."
        case .chatNotStarted(let id):
            "chat \(id) has no finished exchange to draft from: say something with `workbench chat` first."
        case .imagesNeedANewThread: "images can be attached to a new goal, not to a redrafted one."
        case .attachment(let why): why
        case .busy: "another command is using this thread (a run, a judge or another draft); try again when it ends."
        }
    }
}
