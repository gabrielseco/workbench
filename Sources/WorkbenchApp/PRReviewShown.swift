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

    init(pr: Int, round: Int, verdict: PRReviewVerdict?, failure: String?, findings: String?, notes: [String] = []) {
        (self.pr, self.round, self.verdict) = (pr, round, verdict)
        (self.failure, self.findings, self.notes) = (failure, findings, notes)
    }

    init(_ result: PRReviewResult) {
        self.init(
            pr: result.pr, round: result.round, verdict: result.verdict, failure: result.failure, findings: result.findings,
            notes: result.warnings)
        if let skipped = result.skipped { notes.append("Skipped: \(skipped)") }
    }

    /// The round recorded in the log, with what Codex wrote read from its file.
    init(_ record: PRReviewRecord, findings: String?) {
        self.init(
            pr: record.pr, round: record.round, verdict: record.verdict,
            failure: record.verdict == nil ? "the round has no verdict" : nil, findings: findings)
    }

    var headline: String {
        switch verdict {
        case .clean?: "Pull request #\(pr): clean (round \(round))"
        case .fix?: "Pull request #\(pr): findings to fix (round \(round))"
        case nil: "Pull request #\(pr): no verdict (round \(round)): \(failure ?? "unknown")"
        }
    }
}
