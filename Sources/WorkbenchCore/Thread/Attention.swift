import Foundation

/// Why a thread needs a person, and which log record (or commit) it began at, so a reader notifies once per reason.
public struct AttentionReason: Sendable, Equatable {
    public var text: String
    /// The `seq` the reason began at.
    public var since: Int
    /// The pull request's head commit for the two reasons GitHub changes without writing an event (CI), else nil.
    public var commit: String?
}

/// Amber means one thing: the thread cannot go on until you decide, and you can decide now.
public enum Attention: Sendable, Equatable {
    case none
    /// Workbench is working: a turn or check is open, or a PR review round is running.
    case working
    case needsYou(AttentionReason)

    /// - Parameters:
    ///   - checks: the pull request's CI when fetched; without it no CI row is produced.
    ///   - handChecks: the criteria only a person can verify, or the judge says are not met (their ids). The caller
    ///     reads them from a review; `status` does not build one.
    ///   - outcome: a merged or closed pull request is housekeeping, never a request.
    public static func derive(
        spine: ThreadSpine, state: ThreadState, checks: PRChecksSummary? = nil, handChecks: [String] = [],
        outcome: PullRequestOutcome = .open
    ) -> Attention {
        if state.openTurn != nil || state.openCheck != nil || (state.adviceIsOpen && state.decision == nil) { return .working }
        if let decision = state.decision {
            guard decision == "accepted", let pr = state.pullRequest, !state.cleaned, outcome == .open else { return .none }
            return pullRequest(pr, state: state, checks: checks)
        }
        if spine[.review].mark == .needsYou {
            let since = state.lastTurnEndedSeq ?? 0
            if !handChecks.isEmpty {
                let text = handChecks.joined(separator: ", ") + " by hand"
                return .needsYou(AttentionReason(text: text, since: since, commit: nil))
            }
            return .needsYou(AttentionReason(text: "Review · turn \(state.lastTurn) done", since: since, commit: nil))
        }
        return .none
    }

    private static func pullRequest(_ pr: PullRequestRecord, state: ThreadState, checks: PRChecksSummary?) -> Attention {
        let round = state.review.prReview.flatMap { $0.pr == nil || $0.pr == pr.number ? $0 : nil }
        // The commit the latest round reviewed, else the one the pull request opened at: a newer commit is a new reason.
        let commit = round?.headSHA ?? pr.headSHA
        if let failed = checks?.checks.filter({ $0.outcome == .failed }), !failed.isEmpty {
            let text = "CI failed: " + failed.map(\.name).joined(separator: ", ")
            return .needsYou(AttentionReason(text: text, since: pr.seq, commit: commit))
        }
        if let round {
            if round.isOpen { return .working }
            switch round.verdict {
            case "fix": return .needsYou(AttentionReason(text: "Findings open", since: round.seq, commit: nil))
            case "clean":
                if checks?.state == .passed {
                    return .needsYou(AttentionReason(text: "Ready to merge", since: round.seq, commit: commit))
                }
            default:
                let why = round.failure.map { ": " + $0 } ?? ""
                return .needsYou(AttentionReason(text: "Review round \(round.round) failed\(why)", since: round.seq, commit: nil))
            }
        }
        return .none
    }
}
