import Foundation

/// Where a thread stands for the person deciding about it.
public enum ReviewStatus: Sendable, Equatable {
    /// No turn has started.
    case empty
    /// A turn or its check is open.
    case running
    /// A turn ended and nothing is open: the work, even a partial one, can be reviewed.
    case awaitingReview
    /// A note was recorded after the last turn ended; the next turn has not started yet.
    case sentBack
    /// `accepted`, `discarded` or `abandoned`.
    case decided(String)
}

/// What a reviewer needs from the log. Everything is derived by `ThreadState.derive`.
public struct Review: Sendable, Equatable {
    public struct Check: Sendable, Equatable {
        /// The turn the check followed.
        public var turn: Int
        public var result: String
        public var exitCode: Int?
        public var outputRef: String?
    }

    public struct Note: Sendable, Equatable {
        /// The follow-up turn the note started.
        public var turn: Int
        public var seq: Int
        public var text: String
    }

    public struct DeniedTool: Sendable, Equatable {
        public var turn: Int
        public var tool: String
        /// The `seq` of the `claude` line that carries the denial, so a reader can open the raw event.
        public var seq: Int
    }

    public var status: ReviewStatus
    /// The latest turn's `result`, nil when none has ended.
    public var turnResult: String?
    /// The latest completed check, nil when none has run.
    public var check: Check?
    public var notes: [Note]
    public var deniedTools: [DeniedTool]
}

/// What the log says about a thread, derived each time it is asked for. Nothing here is stored twice.
public struct ThreadState: Sendable, Equatable {
    public var id: String
    public var createdAt: String?
    public var lastTurn: Int
    public var openTurn: Int?
    public var openCheck: Int?
    /// The latest check's `result`, nil when no check has run.
    public var lastCheck: String?
    /// `accepted`, `discarded` or `abandoned` once the thread has ended.
    public var decision: String?
    public var lastResult: String?
    public var totalCostUSD: Double
    public var sessionID: String?
    public var review: Review

    public var isActive: Bool { decision == nil }

    public static let terminalDecisions: Set<String> = ["accepted", "discarded", "abandoned"]

    /// A pure function of the events: no file, git or clock. Unknown kinds and unknown decisions are ignored.
    public static func derive(from events: [Event], id: String) -> ThreadState {
        var state = ThreadState(
            id: id, createdAt: nil, lastTurn: 0, openTurn: nil, openCheck: nil, lastCheck: nil, decision: nil,
            lastResult: nil, totalCostUSD: 0, sessionID: nil,
            review: Review(status: .empty, turnResult: nil, check: nil, notes: [], deniedTools: []))
        var noteIsLatest = false
        for event in events {
            switch event.kind {
            case .threadCreated:
                state.createdAt = event.ts
            case .turnStarted:
                state.lastTurn = max(state.lastTurn, event.turn)
                state.openTurn = event.turn
                noteIsLatest = false
                if let session = event.data["session_id"]?.stringValue { state.sessionID = session }
            case .turnEnded:
                if state.openTurn == event.turn { state.openTurn = nil }
                state.lastResult = event.data["result"]?.stringValue
                switch event.data["cost_usd"] {
                case .double(let d)?: state.totalCostUSD += d
                case .int(let i)?: state.totalCostUSD += Double(i)
                default: break
                }
            case .checkStarted:
                state.openCheck = event.turn
            case .checkRan:
                if state.openCheck == event.turn { state.openCheck = nil }
                let result = event.data["result"]?.stringValue
                state.lastCheck = result
                if let result {
                    state.review.check = Review.Check(
                        turn: event.turn, result: result, exitCode: event.data["exit_code"]?.intValue,
                        outputRef: event.data["output_ref"]?.stringValue)
                }
            case .threadNote:
                if let text = event.data["text"]?.stringValue {
                    // The runner writes the note with turn 0, before the turn it starts.
                    state.review.notes.append(
                        Review.Note(turn: state.lastTurn + 1, seq: event.seq, text: text))
                    noteIsLatest = state.openTurn == nil
                }
            case .claude:
                guard event.data["type"]?.stringValue == "result",
                    case .array(let denials)? = event.data["permission_denials"]
                else { break }
                for denial in denials {
                    guard let tool = denial["tool_name"]?.stringValue else { continue }
                    state.review.deniedTools.append(
                        Review.DeniedTool(turn: event.turn, tool: tool, seq: event.seq))
                }
            case .reviewDecision:
                if let decision = event.data["decision"]?.stringValue, terminalDecisions.contains(decision) {
                    state.decision = decision
                }
            default:
                break
            }
        }
        state.review.turnResult = state.lastResult
        if let decision = state.decision {
            state.review.status = .decided(decision)
        } else if state.openTurn != nil || state.openCheck != nil {
            state.review.status = .running
        } else if state.lastTurn == 0 {
            state.review.status = .empty
        } else if noteIsLatest {
            state.review.status = .sentBack
        } else {
            state.review.status = .awaitingReview
        }
        return state
    }
}
