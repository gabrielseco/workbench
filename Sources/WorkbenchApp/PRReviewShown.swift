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
}
