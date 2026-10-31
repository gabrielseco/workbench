import Foundation
import WorkbenchCore

/// One pull request review round as the window shows it: what Codex said and how the round came out.
struct PRReviewShown: Equatable, Sendable {
    var pr: Int
    var round: Int
    var verdict: PRReviewVerdict?
    /// Why there is no verdict; a round without one is a failure, never a pass.
    var failure: String?
    var findings: String?
    var notes: [String] = []
    /// The commit the round read; with the branch's tip now it says whether later pushes were never reviewed.
    var headSHA: String?

    init(
        pr: Int, round: Int, verdict: PRReviewVerdict?, failure: String?, findings: String?, notes: [String] = [],
        headSHA: String? = nil
    ) {
        self.headSHA = headSHA
        (self.pr, self.round, self.verdict) = (pr, round, verdict)
        (self.failure, self.findings, self.notes) = (failure, findings, notes)
    }

    init(_ result: PRReviewResult) {
        self.init(
            pr: result.pr, round: result.round, verdict: result.verdict, failure: result.failure, findings: result.findings,
            notes: result.warnings, headSHA: result.headSHA)
        if let skipped = result.skipped { notes.append("Skipped: \(skipped)") }
    }

    /// The round recorded in the log, with what Codex wrote read from its file and, for a round with no verdict, the reason the
    /// log recorded. `tip` is where the pull request's branch is now: a round that read an earlier commit says so.
    init(_ record: PRReviewRecord, findings: String?, failure: String?, tip: String?) {
        self.init(
            pr: record.pr, round: record.round, verdict: record.verdict,
            failure: record.verdict == nil ? (failure ?? "no reason recorded") : nil, findings: findings,
            notes: record.skipped ? ["Skipped: the diff touches no path this stage applies to."] : [],
            headSHA: record.headSHA)
        markStale(tip: tip)
    }

    /// Says so when the branch has moved since the round read it: its verdict is about an older commit.
    mutating func markStale(tip: String?) {
        guard let headSHA, let tip, headSHA != tip else { return }
        notes.append(
            "Stale: the branch has moved since this round (it read \(headSHA.prefix(7)), now \(tip.prefix(7))). Review again.")
    }

    var headline: String {
        switch verdict {
        case .clean?: "Pull request #\(pr): clean (round \(round))"
        case .fix?: "Pull request #\(pr): findings to fix (round \(round))"
        case nil: "Pull request #\(pr): no verdict (round \(round)): \(failure ?? "unknown")"
        }
    }

    /// Whether a fix round can be started from this round: it found things to fix, and what it found is there to hand on.
    var canFix: Bool {
        verdict == .fix && findings?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
}

/// What "Fix these findings" would start, shown before it does: core's follow-up thread on the pull request's branch.
struct FollowUpPlan: Equatable, Sendable {
    var pr: Int
    /// Which follow-up of this pull request it would be, and how many `[pr_review] max_rounds` allows.
    var round: Int
    var allowed: Int
    /// The most its turn can cost, nil when the project sets no dollar cap (`default_budget_usd`): the turn is then limited by its
    /// timeout only, as every new goal of such a project is.
    var budget: Decimal?
    /// Core's reason there can be none (no rounds left); the confirm says it and offers no start.
    var refusal: String?

    var text: String {
        let cost =
            budget.map { "up to $\(String(format: "%.2f", NSDecimalNumber(decimal: $0).doubleValue))" }
            ?? "with no dollar cap (this project sets none, so only its timeout limits the turn)"
        return "Starts follow-up \(round) of at most \(allowed) on pull request #\(pr): a new thread on the same branch, "
            + "whose goal is these findings, and runs its first turn, \(cost). "
            + "When the turn succeeds and the check passes, it is accepted, pushed to the pull request and reviewed again "
            + "without asking; otherwise it waits for you as any thread. Nothing is merged."
    }
}
