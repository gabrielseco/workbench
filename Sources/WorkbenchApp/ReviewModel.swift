import Foundation
import WorkbenchCore

/// What the Review screen shows, from core's `ReviewReport`. Row labels are core's own words: nothing here decides that a
/// criterion is met, and `manual` and `missing` read as for the person.
struct ReviewModel: Equatable {
    struct Criterion: Equatable, Identifiable {
        var id: String
        var text: String
        var proof: String
        /// Core's label (`✔ passed`, `you check`, `see screenshot`, `✘ missing`), shown as it says it.
        var label: String
        var note: String?
        var forYou: Bool
        var failed: Bool
        /// The recorded screenshot files, or `name (missing)`; empty for a proof that is not a screenshot.
        var evidence: [String]
    }

    struct File: Equatable, Identifiable {
        var path: String
        var text: String
        var id: String { path }
    }

    struct Denied: Equatable, Identifiable {
        var id: String
        var text: String
        var count: Int
    }

    /// `Turn 2 succeeded`; the files and lines follow in `totals`, and the view says when it finished.
    var headline: String
    var totals: String
    var result: String?
    var criteria: [Criterion]
    var criteriaSummary: String
    /// `1 of 4 assessed`: the criteria Workbench could say something about, not a verdict on any of them.
    var assessed: String
    var goalProblem: String?
    var files: [File]
    var filesNote: String?
    var diffProblem: String?
    var commits: [String]
    var check: String
    var denied: [Denied]
    var notes: [String]
    /// How many criteria are for the person: Accept says it, and is never blocked by it.
    var undecided: Int
    var canDecide: Bool

    static func derive(_ report: ReviewReport) -> ReviewModel {
        let state = report.state
        let statuses = report.goalProblem == nil ? report.criterionStatuses : []
        let texts = Dictionary(report.criteria.map { ($0.id, $0.text) }, uniquingKeysWith: { first, _ in first })
        let criteria = statuses.map { status in
            Criterion(
                id: status.id, text: texts[status.id] ?? "", proof: status.proof, label: status.label, note: status.note,
                forYou: status.state != .passed && status.state != .failed, failed: status.state == .failed,
                evidence: status.screenshots.map { $0.path.map { path in path } ?? "\($0.name) (missing)" })
        }
        var files: [File] = []
        var filesNote: String?
        var diffProblem: String?
        var totals = ""
        switch report.diff {
        case .summary(let summary):
            files = summary.files.map { File(path: $0.path, text: describe($0)) }
            if summary.truncated { filesNote = "Too many files: \(files.count) of \(summary.totalFiles) shown." }
            let noun = summary.totalFiles == 1 ? "file" : "files"
            totals = "\(summary.totalFiles) \(noun) · +\(summary.additions) −\(summary.deletions)"
        case .unavailable(let reason):
            diffProblem = "Diff unavailable: \(reason)"
        }
        let result = state.review.turnResult
        var headline = "Turn \(state.lastTurn)"
        if let result { headline += " \(result.replacingOccurrences(of: "_", with: " "))" }
        let groups = Dictionary(grouping: state.review.deniedTools, by: { $0.tool + "\u{0}" + $0.identity })
        let denied = groups.values.sorted { $0[0].seq < $1[0].seq }.map {
            Denied(id: "\($0[0].seq)", text: $0[0].label, count: $0.count)
        }
        return ReviewModel(
            headline: headline, totals: totals, result: result, criteria: criteria,
            criteriaSummary: CriteriaStatus.summary(statuses, check: state.review.check),
            assessed: "\(criteria.count - criteria.filter(\.forYou).count) of \(criteria.count) assessed",
            goalProblem: report.goalProblem,
            files: files, filesNote: filesNote, diffProblem: diffProblem,
            commits: report.commits.map { "\($0.sha.prefix(12)) \($0.subject)" }
                + (report.commitCount > report.commits.count ? ["… and \(report.commitCount - report.commits.count) more"] : []),
            check: checkText(state.review.check), denied: denied,
            notes: state.review.notes.map { "turn \($0.turn): " + ReviewReport.oneLine($0.text) },
            undecided: criteria.filter(\.forYou).count,
            canDecide: report.status == .awaitingReview && diffProblem == nil)
    }

    static func checkText(_ check: Review.Check?) -> String {
        guard let check else { return "none ran" }
        var text = check.result
        if let code = check.exitCode { text += " (exit \(code))" }
        if let command = check.command { text += " · \(command)" }
        return text
    }

    private static func describe(_ file: FileChange) -> String {
        let mark =
            switch file.status {
            case .added: file.isUntracked ? "?" : "A"
            case .modified: "M"
            case .deleted: "D"
            case .renamed: "R"
            }
        var text = "\(mark)  " + (file.oldPath.map { "\($0) → \(file.path)" } ?? file.path)
        if file.isBinary {
            text += "  binary"
        } else if let added = file.additions, let removed = file.deletions {
            text += "  +\(added) −\(removed)"
        } else {
            text += "  counts unavailable"
        }
        return text
    }
}
