import Foundation

/// Whether the thread is waiting for its person (docs/plan/P19-swiftui-app.md, "The amber needs you rule"). Pure:
/// a screen, a notification and `status` all read this one answer.
public enum Attention: Sendable, Equatable {
    /// What a "needs you" is de-duplicated on: the `seq` it began at, or for a CI-driven reason the pull request's
    /// head commit, since a GitHub check change writes no event.
    public enum Since: Sendable, Equatable {
        case seq(Int)
        case commit(String)
    }

    case none
    case working
    case needsYou(reason: String, since: Since)

    /// `remote` is what GitHub says about the pull request; without it no CI-based reason is given. `byHand` are
    /// criteria only a person can verify (from the review report); criteria the judge found not met are added here.
    public static func derive(
        state: ThreadState, remote: PullRequestRemote? = nil, byHand: [String] = []
    ) -> Attention {
        if state.decision == "discarded" || state.decision == "abandoned" { return .none }
        // A running turn, check, verifier, judge or review round is never amber, whatever it was denied.
        if state.openTurn != nil || state.openCheck != nil || state.review.verifier?.open == true || state.judgeOpen
            || state.prReviewOpen {
            return .working
        }
        if state.review.status == .awaitingReview, let seq = state.lastTurnEndedSeq {
            return .needsYou(reason: reviewReason(state, byHand: byHand), since: .seq(seq))
        }
        guard state.decision == "accepted", let pr = state.pullRequest,
            ThreadSpine.pullRequestEnd(state, remote) == nil
        else { return .none }
        // Below: an open pull request. A merged one waiting for Clean is housekeeping, not a request.
        let round = ThreadSpine.latestRound(state)
        if let round, let failure = round.failure {
            return .needsYou(reason: "Review round \(round.round) failed: \(failure)", since: .seq(round.seq))
        }
        if let round, round.verdict == "fix" {
            return .needsYou(reason: "Review round \(round.round): findings open", since: .seq(round.seq))
        }
        guard let checks = remote?.checks else { return .none }
        let commit = Since.commit(pr.headSHA ?? "pr-\(pr.number)")
        if checks.state == .failed { return .needsYou(reason: ciFailedReason(checks), since: commit) }
        if checks.state == .passed, round?.verdict == "clean" { return .needsYou(reason: "Ready to merge", since: commit) }
        return .none
    }

    /// `CI failed: unit tests, lint`.
    static func ciFailedReason(_ checks: PRChecksSummary?) -> String {
        let names = (checks?.checks ?? []).filter { $0.outcome == .failed }.map(\.name)
        return names.isEmpty ? "CI failed" : "CI failed: " + names.prefix(3).joined(separator: ", ")
    }

    private static func reviewReason(_ state: ThreadState, byHand: [String]) -> String {
        let result = state.lastResult.map { $0 == "succeeded" ? "done" : $0 } ?? "ended"
        var reason = "Review · turn \(state.lastTurn) \(result)"
        // A verdict on an earlier turn says nothing about this one.
        let judge = state.review.judge.flatMap { $0.turn == state.lastTurn ? $0.verdict : nil }
        let notMet = judge?.criteria.filter { !$0.met }.map(\.id) ?? []
        var ids: [String] = []
        for id in byHand + notMet where !ids.contains(id) { ids.append(id) }
        if !ids.isEmpty { reason += " · " + ids.joined(separator: ", ") + " by hand" }
        return reason
    }
}
