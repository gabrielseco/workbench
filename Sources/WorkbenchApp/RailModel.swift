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

/// What the rail lists: the project's threads, then its scheduled tasks. Pure, so the sections are tested
/// without a window.
struct RailModel: Equatable {
    /// The thread being started on the new-thread screen: a row of its own at the top, selected, until something is chosen.
    var composing: RailRow?
    var threads: [RailRow]
    var older: Int
    var tasks: [RailRow]
    /// A task's finished threads (done or idle), newest first, by task name: they are listed under it, not in `threads`.
    var taskThreads: [String: [RailRow]] = [:]
    /// The tasks have been read; until then the section says so rather than claiming there are none.
    var tasksRead: Bool

    static let composingRow = RailRow(
        kind: .thread, key: "new-thread", title: "New thread", mark: .idle, line: "Type to start · free")

    static func derive(listing: ThreadListing, tasks: TasksSnapshot?, composing: Bool = false) -> RailModel {
        let (own, grouped) = split(listing.rows, tasks: tasks)
        return RailModel(
            composing: composing ? composingRow : nil, threads: own.map(RailRow.thread), older: listing.older,
            tasks: tasks?.entries.map(RailRow.task) ?? [], taskThreads: grouped.mapValues { $0.map(RailRow.thread) },
            tasksRead: tasks != nil)
    }

    /// The thread's rows that stay in THREADS, and the finished ones a task started, by task. A thread is a task's when a task's run log
    /// names it, so threads from before this existed qualify too. One that is working, needs you or is broken stays where it is seen,
    /// and goes under its task once it ends. Until the tasks are read nothing moves.
    static func split(_ rows: [ThreadRow], tasks: TasksSnapshot?) -> (own: [ThreadRow], grouped: [String: [ThreadRow]]) {
        guard let tasks else { return (rows, [:]) }
        var owner: [String: String] = [:]
        for entry in tasks.entries {
            for thread in entry.runs.compactMap(\.thread) where owner[thread] == nil { owner[thread] = entry.id }
        }
        var own: [ThreadRow] = []
        var grouped: [String: [ThreadRow]] = [:]
        for row in rows {
            if let task = owner[row.id], row.mark == .done || row.mark == .idle {
                grouped[task, default: []].append(row)
            } else {
                own.append(row)
            }
        }
        return (own, grouped)
    }

    /// The task whose group holds this thread, if one does: what the rail opens so a chosen thread is never hidden in a closed group.
    func group(holding thread: String?) -> String? {
        guard let thread else { return nil }
        return taskThreads.first { $0.value.contains { $0.key == thread } }?.key
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
