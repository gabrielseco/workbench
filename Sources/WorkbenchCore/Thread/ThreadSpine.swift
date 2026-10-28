import Foundation

public enum SpineStep: String, Sendable, CaseIterable {
    case goal, run, review, accept, ship, prReview = "pr review", clean

    public var title: String {
        switch self {
        case .goal: "Goal"
        case .run: "Run"
        case .review: "Review"
        case .accept: "Accept"
        case .ship: "Ship"
        case .prReview: "PR review"
        case .clean: "Clean"
        }
    }
}

public enum SpineMark: String, Sendable, Equatable {
    case done, current, needsYou = "needs_you", pending, failed
}

/// What GitHub says became of the pull request. The log does not record it until `clean`, so the caller supplies it.
public enum PullRequestOutcome: Sendable, Equatable {
    case open, merged, closed
}

/// The thread's state machine drawn as seven steps, a pure function of what the log and the goal file say. A reader
/// renders it and stores nothing, so there is no second state machine to drift from the log.
public struct ThreadSpine: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public var step: SpineStep
        public var mark: SpineMark
        public var sublabel: String
    }

    public var entries: [Entry]

    /// The entry of a step; `derive` always makes all seven.
    public subscript(step: SpineStep) -> Entry {
        entries.first { $0.step == step } ?? Entry(step: step, mark: .pending, sublabel: "")
    }

    /// - Parameters:
    ///   - approval: the goal file's state; nil when there is no readable goal file, which falls back to the log's
    ///     latest `goal.approved`.
    ///   - outcome: the pull request's fate when the caller knows it.
    ///   - checks: the pull request's CI when the caller fetched it; nil is "not checked", never "green".
    public static func derive(
        state: ThreadState, approval: ApprovalState? = nil, outcome: PullRequestOutcome = .open,
        checks: PRChecksSummary? = nil
    ) -> ThreadSpine {
        let approved = approval.map { $0 == .approved } ?? (state.approvedGoalHash != nil)
        let review = state.review
        let decided = state.decision != nil
        let accepted = state.decision == "accepted"
        let pr = state.pullRequest

        var goal = Entry(step: .goal, mark: .done, sublabel: "Approved")
        if !approved && !decided {
            let stale = approval == .stale
            goal = Entry(step: .goal, mark: .current, sublabel: stale ? "Changed since approval" : "Writing")
        }

        let run: Entry
        if let open = state.openTurn {
            run = Entry(step: .run, mark: .current, sublabel: "Turn \(open) · working")
        } else if state.openCheck != nil {
            run = Entry(step: .run, mark: .current, sublabel: "Turn \(state.lastTurn) · checking")
        } else if state.lastTurn == 0 {
            run = Entry(step: .run, mark: decided || !approved ? .pending : .current, sublabel: approved ? "Not started" : "")
        } else if review.status == .sentBack {
            run = Entry(step: .run, mark: .current, sublabel: "Turn \(state.lastTurn + 1) · send-back")
        } else {
            let ok = state.lastResult == "succeeded"
            run = Entry(
                step: .run, mark: ok ? .done : .failed,
                sublabel: "Turn \(state.lastTurn) · " + (ok ? cost(state) : "\(state.lastResult ?? "ended") · \(cost(state))"))
        }

        let reviewEntry: Entry
        if let decision = state.decision {
            reviewEntry = Entry(step: .review, mark: .done, sublabel: decision.capitalized)
        } else if review.status == .awaitingReview {
            reviewEntry = Entry(step: .review, mark: .needsYou, sublabel: "Needs you")
        } else {
            reviewEntry = Entry(step: .review, mark: .pending, sublabel: "")
        }

        let accept =
            accepted
            ? Entry(step: .accept, mark: .done, sublabel: "Accepted") : Entry(step: .accept, mark: .pending, sublabel: "")

        let ship: Entry
        if let pr {
            let word = outcome == .open ? "open" : (outcome == .merged ? "merged" : "closed")
            ship = Entry(step: .ship, mark: .done, sublabel: "PR #\(pr.number) \(word)")
        } else {
            ship = Entry(step: .ship, mark: accepted ? .current : .pending, sublabel: accepted ? "Not shipped" : "")
        }

        let prReview = prReviewEntry(state: state, pr: pr, checks: checks)

        let clean: Entry
        if state.cleaned {
            clean = Entry(step: .clean, mark: .done, sublabel: "Branch removed")
        } else if pr != nil && outcome != .open {
            clean = Entry(step: .clean, mark: .current, sublabel: "Run `workbench clean`")
        } else {
            clean = Entry(step: .clean, mark: .pending, sublabel: "")
        }

        return ThreadSpine(entries: [goal, run, reviewEntry, accept, ship, prReview, clean])
    }

    private static func prReviewEntry(state: ThreadState, pr: PullRequestRecord?, checks: PRChecksSummary?) -> Entry {
        guard let pr else { return Entry(step: .prReview, mark: .pending, sublabel: "") }
        // A round that reviewed another pull request does not count for this one.
        let round = state.review.prReview.flatMap { $0.pr == nil || $0.pr == pr.number ? $0 : nil }
        if let failed = checks?.checks.filter({ $0.outcome == .failed }), !failed.isEmpty {
            return Entry(step: .prReview, mark: .needsYou, sublabel: "CI failed: " + failed.map(\.name).joined(separator: ", "))
        }
        guard let round else { return Entry(step: .prReview, mark: .current, sublabel: "No review yet") }
        if round.isOpen { return Entry(step: .prReview, mark: .current, sublabel: "Round \(round.round) · running") }
        switch round.verdict {
        case "fix": return Entry(step: .prReview, mark: .needsYou, sublabel: "Findings open")
        case "clean":
            switch checks?.state {
            case .passed?: return Entry(step: .prReview, mark: .done, sublabel: "Clean · CI passed")
            case .pending?: return Entry(step: .prReview, mark: .current, sublabel: "Clean · CI running")
            case .none?: return Entry(step: .prReview, mark: .done, sublabel: "Clean")
            case nil: return Entry(step: .prReview, mark: .done, sublabel: "Clean · CI not checked")
            case .failed?: return Entry(step: .prReview, mark: .needsYou, sublabel: "CI failed")
            }
        default:
            return Entry(step: .prReview, mark: .failed, sublabel: "Round \(round.round) failed")
        }
    }

    private static func cost(_ state: ThreadState) -> String {
        state.knownCostUSD.map { String(format: "$%.2f", $0) } ?? "cost unknown"
    }
}
