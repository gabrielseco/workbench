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

/// What the rail lists with the chat feed preview on: the project's threads, then its scheduled tasks. Pure, so the sections are tested
/// without a window.
struct RailModel: Equatable {
    /// The thread being started on the new-thread screen: a row of its own at the top, selected, until something is chosen.
    var composing: RailRow?
    var threads: [RailRow]
    var older: Int
    var tasks: [RailRow]
    /// The tasks have been read; until then the section says so rather than claiming there are none.
    var tasksRead: Bool

    static let composingRow = RailRow(
        kind: .thread, key: "new-thread", title: "New thread", mark: .idle, line: "Type to start · free")

    static func derive(listing: ThreadListing, tasks: TasksSnapshot?, composing: Bool = false) -> RailModel {
        RailModel(
            composing: composing ? composingRow : nil, threads: listing.rows.map(RailRow.thread), older: listing.older,
            tasks: tasks?.entries.map(RailRow.task) ?? [], tasksRead: tasks != nil)
    }

    var scheduledHeader: String { "SCHEDULED · \(tasks.count)" }

    /// What the Scheduled section says when it has no rows.
    var scheduledNote: String? {
        guard tasks.isEmpty else { return nil }
        return tasksRead ? "No scheduled tasks. Make one with workbench task new <name>." : "Reading…"
    }
}

extension ThreadMark {
    /// The colour of a state line: only a state that asks something of the person, or says a thing finished, is coloured.
    var lineTint: ThreadMarkTint { self == .idle ? .quiet : .mark }
}

enum ThreadMarkTint { case quiet, mark }
