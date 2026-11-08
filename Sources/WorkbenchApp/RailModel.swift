import Foundation

/// One row of the rail: a thread or a scheduled task, said the same way (P22 design parity 4). The mark carries the colour, the line says
/// the state in words, coloured by the same mark.
struct RailRow: Equatable, Identifiable {
    enum Kind: String, Equatable { case thread, task }

    var kind: Kind
    /// The thread's id or the task's name.
    var key: String
    var title: String
    var mark: ThreadMark
    var line: String

    var id: String { "\(kind.rawValue)-\(key)" }

    /// What the row says in words, now that the row itself is one line: the hover text, and what an assistive technology reads.
    var help: String { "\(title): \(line)" }
    var accessibility: String { "\(title), \(mark.word), \(line)" }

    static func thread(_ row: ThreadRow) -> RailRow {
        RailRow(kind: .thread, key: row.id, title: row.title, mark: row.mark, line: row.line)
    }

    /// A task: running first, then what keeps it from running (a file that does not load, an approval that is stale or missing), then how
    /// the last run ended. One line: its schedule, then that.
    static func task(_ entry: TaskEntry) -> RailRow {
        let summary = entry.summary
        let mark: ThreadMark
        let detail: String
        if entry.isRunning {
            (mark, detail) = (.working, "running")
        } else if summary.problem != nil {
            (mark, detail) = (.broken, "needs a fix")
        } else if summary.approval == .stale {
            (mark, detail) = (.needsYou, "approval stale")
        } else if summary.approval == .never {
            (mark, detail) = (.needsYou, "not approved")
        } else if let outcome = entry.runs.first?.outcome {
            switch TaskOutcomeStyle.tone(outcome) {
            case .done: mark = .done
            case .broken: mark = .broken
            case .needsYou: mark = .needsYou
            case .idle, .working: mark = .idle
            }
            detail = TaskOutcomeStyle.word(outcome)
        } else {
            (mark, detail) = (.idle, "never run")
        }
        return RailRow(
            kind: .task, key: summary.name, title: summary.name, mark: mark, line: "\(summary.schedule ?? "manual") · \(detail)")
    }
}

extension ThreadMark {
    /// The colour of a state line: only a state that asks something of the person, or says a thing finished, is coloured.
    var lineTint: ThreadMarkTint { self == .idle ? .quiet : .mark }
}

enum ThreadMarkTint { case quiet, mark }
