import Foundation

/// One row of a thread's feed: what happened, in the order it happened, as data a view only has to draw (P22). Derived from the
/// log, the goal and the state; nothing here is stored, and no text is markup.
public struct FeedItem: Sendable, Equatable, Identifiable {
    public enum Phase: Sendable, Equatable {
        case working
        /// The turn is open in the log and no runner holds it.
        case orphaned
        case ended(result: String)
        /// The log never says how the turn ended and it is not the open one (a damaged log).
        case unrecorded
    }

    public enum Notice: Sendable, Equatable {
        /// Events the log could not keep (`agent.activity` past its cap), or that this feed folded to stay small.
        case activityNotStored(count: Int)
        /// `refusals` of the folded items were refused calls (kept first, up to the cap; the rest are only counted).
        case activityFolded(count: Int, refusals: Int)
        /// A line or an ordering that broke the log's rules; what could be read is shown.
        case logDamaged(problems: Int, first: String)
        /// The last line was cut short, as a crash leaves it.
        case logTailCut
        case goalChangedSinceApproval
        case earlierNotShown(count: Int)
    }

    public enum Kind: Sendable, Equatable {
        case userNote(text: String)
        /// `hash` is the latest approved revision the log names, else the latest saved one.
        case goalCard(title: String?, approval: ApprovalState?, criteria: Int, hash: String?)
        case turn(number: Int, phase: Phase, durationMs: Int?, costUSD: Double?)
        case agentText(String)
        /// Consecutive tool calls other than edits: how many, and the first few summaries.
        case toolGroup(count: Int, summaries: [String])
        case edit(file: String, tool: String)
        /// A call the run refused, with what it was for when the turn recorded it.
        case denied(tool: String, input: String?)
        case check(result: String, command: String?, durationMs: Int?)
        case judge(ok: Bool, criteria: Int, unmet: Int, concerns: Int)
        case verify(ok: Bool, reason: String?, proofs: [String])
        case decision(String)
        case pullRequest(number: Int?, url: String?)
        case prReview(round: Int?, verdict: String?, ok: Bool)
        /// The one next step and why, from the spine and attention; nil when nothing is left.
        case next(step: SpineStep?, why: String)
        case notice(Notice)
    }

    /// `"<seq>"`, `"<seq>.<n>"` for a second item from one event, or a fixed word for one that belongs to no event.
    public var id: String
    /// The log event it came from; 0 when it comes from none.
    public var seq: Int
    public var turn: Int
    public var kind: Kind

    public init(id: String, seq: Int, turn: Int, kind: Kind) { (self.id, self.seq, self.turn, self.kind) = (id, seq, turn, kind) }
}
