import Foundation

/// What GitHub says about the pull request, which no event records: read by the caller (the app polls it), never
/// here. nil wherever it is not known, and nothing CI-based is derived without it.
public struct PullRequestRemote: Sendable, Equatable {
    public enum State: String, Sendable, Equatable {
        case open, merged, closed
    }

    public var state: State
    public var checks: PRChecksSummary?

    public init(state: State, checks: PRChecksSummary? = nil) {
        self.state = state
        self.checks = checks
    }
}

/// The thread's state machine as seven steps, read from the log (docs/plan/P19-swiftui-app.md, "The thread spine").
/// Pure: no file, git, network or clock. A screen renders it and stores nothing.
public struct ThreadSpine: Sendable, Equatable {
    public enum Step: String, Sendable, Equatable, CaseIterable {
        case goal = "Goal"
        case run = "Run"
        case review = "Review"
        case accept = "Accept"
        case ship = "Ship"
        case prReview = "PR review"
        case clean = "Clean"
    }

    public enum Mark: String, Sendable, Equatable {
        case done, current, needsYou, pending, failed
    }

    public struct Entry: Sendable, Equatable {
        public var step: Step
        public var mark: Mark
        public var sublabel: String
    }

    /// Always the seven steps, in order.
    public var entries: [Entry]

    public func mark(_ step: Step) -> Mark { entries.first { $0.step == step }?.mark ?? .pending }
    public func sublabel(_ step: Step) -> String { entries.first { $0.step == step }?.sublabel ?? "" }

    /// `goal` is how the goal file stands against its approval, nil when there is no readable goal file.
    public static func derive(
        state: ThreadState, goal: ApprovalState?, remote: PullRequestRemote? = nil
    ) -> ThreadSpine {
        let goalEntry = goalStep(state, goal)
        let run = runStep(state, goalDone: goalEntry.mark == .done)
        let review = reviewStep(state)
        let accepted = state.decision == "accepted"
        let accept = Entry(
            step: .accept, mark: accepted ? .done : .pending,
            sublabel: accepted ? state.acceptedCommit.map { "commit \($0.prefix(7))" } ?? "Accepted" : "")
        let ship: Entry
        if let pr = state.pullRequest {
            ship = Entry(step: .ship, mark: .done, sublabel: "PR #\(pr.number) open")
        } else {
            ship = Entry(step: .ship, mark: accepted ? .current : .pending, sublabel: accepted ? "Ready to ship" : "")
        }
        let ended = pullRequestEnd(state, remote)
        return ThreadSpine(entries: [
            goalEntry, run, review, accept, ship, prReviewStep(state, remote, ended: ended),
            cleanStep(state, ended: ended),
        ])
    }

    /// How the pull request ended: `merged` or `closed` from `branch.removed`, else from GitHub when it was asked.
    static func pullRequestEnd(_ state: ThreadState, _ remote: PullRequestRemote?) -> String? {
        guard state.pullRequest != nil else { return nil }
        if let reason = state.branchRemoved { return reason }
        guard let remote, remote.state != .open else { return nil }
        return remote.state.rawValue
    }

    /// The latest review round of the thread's own pull request.
    static func latestRound(_ state: ThreadState) -> Review.PRReview? {
        guard let pr = state.pullRequest, let round = state.review.prReview, round.pr == nil || round.pr == pr.number
        else { return nil }
        return round
    }

    /// `HH:MM` of a log timestamp (UTC, as the log writes it).
    static func clock(_ ts: String?) -> String? {
        guard let ts, ts.count >= 16 else { return nil }
        let start = ts.index(ts.startIndex, offsetBy: 11)
        return String(ts[start..<ts.index(start, offsetBy: 5)])
    }

    private static func goalStep(_ state: ThreadState, _ goal: ApprovalState?) -> Entry {
        // Once decided, a later edit to the goal file does not reopen the goal.
        if goal == .approved || (state.decision != nil && state.approvedGoalHash != nil)
            || (goal == nil && state.approvedGoalHash != nil) {
            return Entry(step: .goal, mark: .done, sublabel: clock(state.approvedAt).map { "Approved \($0)" } ?? "Approved")
        }
        if state.decision != nil { return Entry(step: .goal, mark: .pending, sublabel: "") }
        return Entry(step: .goal, mark: .current, sublabel: goal == .stale ? "Changed since approval" : "Writing")
    }

    private static func runStep(_ state: ThreadState, goalDone: Bool) -> Entry {
        if let turn = state.openTurn { return Entry(step: .run, mark: .current, sublabel: "Turn \(turn) · working") }
        if let turn = state.openCheck { return Entry(step: .run, mark: .current, sublabel: "Turn \(turn) · checking") }
        if state.review.verifier?.open == true {
            return Entry(step: .run, mark: .current, sublabel: "Turn \(state.lastTurn) · verifying")
        }
        if state.lastTurn == 0 {
            let ready = goalDone && state.decision == nil
            return Entry(step: .run, mark: ready ? .current : .pending, sublabel: ready ? "Ready to run" : "")
        }
        if state.review.status == .sentBack {
            return Entry(step: .run, mark: .current, sublabel: "Turn \(state.lastTurn + 1) · sent back")
        }
        var label = "Turn \(state.lastTurn)"
        if let result = state.lastResult, result != "succeeded" {
            label += " · \(result)"
        } else {
            label += state.knownCostUSD.map { String(format: " · $%.2f", $0) } ?? " · cost unknown"
        }
        if state.lastTurn > 1 { label += " (send-back)" }
        return Entry(step: .run, mark: .done, sublabel: label)
    }

    private static func reviewStep(_ state: ThreadState) -> Entry {
        switch state.review.status {
        case .decided("accepted"): Entry(step: .review, mark: .done, sublabel: "Accepted")
        // Discarded or abandoned: Review is where the thread ended, with the decision.
        case .decided(let decision): Entry(step: .review, mark: .failed, sublabel: decision.capitalized)
        case .awaitingReview: Entry(step: .review, mark: .needsYou, sublabel: "Needs you")
        default: Entry(step: .review, mark: .pending, sublabel: "")
        }
    }

    private static func prReviewStep(_ state: ThreadState, _ remote: PullRequestRemote?, ended: String?) -> Entry {
        guard state.pullRequest != nil else { return Entry(step: .prReview, mark: .pending, sublabel: "") }
        switch ended {
        case "merged"?: return Entry(step: .prReview, mark: .done, sublabel: "Merged")
        case .some: return Entry(step: .prReview, mark: .failed, sublabel: "Closed without merging")
        case nil: break
        }
        guard let round = latestRound(state) else {
            if remote?.checks?.state == .failed { return ciFailed(remote) }
            return Entry(step: .prReview, mark: .current, sublabel: "Not reviewed yet")
        }
        if state.prReviewOpen {
            return Entry(step: .prReview, mark: .current, sublabel: "Round \(round.round) · running")
        }
        if let failure = round.failure {
            return Entry(step: .prReview, mark: .needsYou, sublabel: "Round \(round.round) failed: \(failure)")
        }
        if round.verdict == "fix" {
            return Entry(step: .prReview, mark: .needsYou, sublabel: "Round \(round.round) · findings open")
        }
        switch remote?.checks?.state {
        case .failed?: return ciFailed(remote)
        case .passed?: return Entry(step: .prReview, mark: .done, sublabel: "Ready to merge")
        case .pending?: return Entry(step: .prReview, mark: .current, sublabel: "Round \(round.round) clean · CI running")
        default: return Entry(step: .prReview, mark: .current, sublabel: "Round \(round.round) clean")
        }
    }

    private static func ciFailed(_ remote: PullRequestRemote?) -> Entry {
        Entry(step: .prReview, mark: .needsYou, sublabel: Attention.ciFailedReason(remote?.checks))
    }

    private static func cleanStep(_ state: ThreadState, ended: String?) -> Entry {
        if state.branchRemoved != nil { return Entry(step: .clean, mark: .done, sublabel: "Branch removed") }
        if ended != nil { return Entry(step: .clean, mark: .current, sublabel: "Ready to clean") }
        return Entry(step: .clean, mark: .pending, sublabel: "")
    }
}
