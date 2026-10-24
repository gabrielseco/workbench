/// A way a log can break the invariants in `docs/spec/event-log.md`.
public enum LogProblem: Error, Equatable, Sendable {
    /// A complete line that is not a valid event envelope. `line` is 1-based.
    case invalidLine(line: Int)
    /// `seq` is not the previous value plus one (invariant 2).
    case seqMismatch(expected: Int, found: Int, line: Int)
    /// `turn.started` while another turn has not ended (invariant 1).
    case turnStartedWhileOpen(turn: Int, open: Int, line: Int)
    /// Turns are numbered 1, 2, 3 with no gaps.
    case turnNotConsecutive(expected: Int, found: Int, line: Int)
    /// `turn.ended` for a turn that is not the open one (invariant 1).
    case turnEndedWithoutStart(turn: Int, line: Int)
    /// A `claude` line outside an open turn.
    case claudeOutsideTurn(turn: Int, line: Int)
    /// An `agent.activity` outside an open turn.
    case activityOutsideTurn(turn: Int, line: Int)
    /// `check.started` while another check has not ended.
    case checkStartedWhileOpen(turn: Int, open: Int, line: Int)
    /// `check.ran` for a turn whose check is not the open one.
    case checkRanWithoutStart(turn: Int, line: Int)
}

/// The rules the writer enforces on append and the reader checks on replay, in one place so they cannot
/// drift apart. Orphaned turns and checks (open at end of file) are state, not a problem: they are what
/// crash recovery looks for.
struct LogState: Sendable {
    var nextSeq = 1
    var openTurn: Int?
    var lastTurn = 0
    /// The turn whose check started and has not ended.
    var openCheck: Int?
    /// The turn whose verify step started and has not ended. Tracked for crash recovery only: it is not an
    /// invariant, so a stray `verify.ended` is not a problem.
    var openVerify: Int?
    /// The `plan.started` no `plan.ended` has closed. Crash recovery only, like verify: not an invariant.
    var planStart: Event?
    /// The `verifier.started` no `verifier.ended` has closed. Crash recovery only, like the plan.
    var verifierStart: Event?
    /// The `run.started` no `run.ended` has closed: the verifier's app. Crash recovery only.
    var runStart: Event?

    /// The `judge.started` no `judge.ran` has closed, oldest first. Crash recovery only: a killed judge is closed on the
    /// next start, so more than one is only in a log from before that existed.
    var judgeStarts: [Event] = []
    /// The `pr_review.started` and `review_stage.started` no matching finish has closed, oldest first. Crash recovery only.
    var reviewStarts: [Event] = []
    /// The `goal.draft.started` no `goal.draft.finished` has closed, oldest first. Crash recovery only.
    var draftStarts: [Event] = []
    /// Every `agent.attempt.started` no `agent.attempt.ended` has closed, by attempt id. Crash recovery only.
    var openAttempts: [String: Event] = [:]

    func check(_ event: Event, line: Int = 0) -> LogProblem? {
        if event.seq != nextSeq {
            return .seqMismatch(expected: nextSeq, found: event.seq, line: line)
        }
        switch event.kind {
        case .turnStarted:
            if let open = openTurn {
                return .turnStartedWhileOpen(turn: event.turn, open: open, line: line)
            }
            if event.turn != lastTurn + 1 {
                return .turnNotConsecutive(expected: lastTurn + 1, found: event.turn, line: line)
            }
        case .turnEnded:
            if openTurn != event.turn {
                return .turnEndedWithoutStart(turn: event.turn, line: line)
            }
        case .claude:
            if openTurn != event.turn {
                return .claudeOutsideTurn(turn: event.turn, line: line)
            }
        case .agentActivity:
            if openTurn != event.turn {
                return .activityOutsideTurn(turn: event.turn, line: line)
            }
        case .checkStarted:
            if let open = openCheck {
                return .checkStartedWhileOpen(turn: event.turn, open: open, line: line)
            }
        case .checkRan:
            if openCheck != event.turn {
                return .checkRanWithoutStart(turn: event.turn, line: line)
            }
        default:
            break
        }
        return nil
    }

    mutating func apply(_ event: Event) {
        nextSeq = event.seq + 1
        switch event.kind {
        case .turnStarted:
            openTurn = event.turn
            lastTurn = event.turn
        case .turnEnded:
            openTurn = nil
        case .checkStarted:
            openCheck = event.turn
        case .checkRan:
            openCheck = nil
        case .verifyStarted:
            openVerify = event.turn
        case .verifyEnded:
            openVerify = nil
        case .planStarted:
            planStart = event
        case .planEnded:
            planStart = nil
        case .runStarted:
            runStart = event
        case .runEnded:
            runStart = nil
        case .verifierStarted:
            verifierStart = event
        case .verifierEnded:
            verifierStart = nil
        case .judgeStarted:
            judgeStarts.append(event)
        case .judgeRan:
            if !judgeStarts.isEmpty { judgeStarts.removeLast() }
        case .prReviewStarted, .reviewStageStarted:
            reviewStarts.append(event)
        case .prReviewFinished, .reviewStageFinished:
            // A skip writes a finish with no start, so a finish only closes the latest start it matches.
            if let at = reviewStarts.lastIndex(where: { Self.finish(event, closes: $0) }) { reviewStarts.remove(at: at) }
        case .goalDraftStarted:
            draftStarts.append(event)
        case .goalDraftFinished:
            if !draftStarts.isEmpty { draftStarts.removeLast() }
        case .agentAttemptStarted:
            if let id = event.data["attempt"]?.stringValue { openAttempts[id] = event }
        case .agentAttemptEnded:
            if let id = event.data["attempt"]?.stringValue { openAttempts[id] = nil }
        default:
            break
        }
    }

    private static func finish(_ finish: Event, closes start: Event) -> Bool {
        let stage = start.kind == .reviewStageStarted ? start.data["stage"]?.stringValue : nil
        let isStage = finish.kind == .reviewStageFinished
        guard isStage == (start.kind == .reviewStageStarted) else { return false }
        return !isStage || finish.data["stage"]?.stringValue == stage
    }
}
