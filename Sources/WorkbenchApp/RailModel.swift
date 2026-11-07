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

/// What the rail lists: the project's threads, then its scheduled tasks. Pure, so the sections are tested
/// without a window.
struct RailModel: Equatable {
    /// The thread being started on the new-thread screen: a row of its own at the top, selected, until something is chosen.
    var composing: RailRow?
    /// The threads listed, at most the limit: the one on screen, then the ones that need you, are working or are broken, then the newest of
    /// the rest; newest first, as the listing is.
    var threads: [RailRow]
    /// How many threads the limit left out: what `Show more` would add.
    var hidden: Int
    /// How many older threads the listing itself left out (past the loader's cap).
    var older: Int
    var tasks: [RailRow]
    /// The tasks have been read; until then the section says so rather than claiming there are none.
    var tasksRead: Bool

    /// What the "N older threads" line says when it is hovered: they are past what the app loads, and the command that lists them.
    static func olderHelp(_ older: Int) -> String {
        let subject = older == 1 ? "1 older thread is" : "\(older) older threads are"
        return "\(subject) past the 50 the app loads. `workbench status --all` lists them, `workbench log <id>` shows one."
    }

    /// How many threads are listed, and how many each `Show more` adds.
    static let pageSize = 10

    static let composingRow = RailRow(
        kind: .thread, key: "new-thread", title: "New thread", mark: .idle, line: "Type to start · free")

    /// - Parameters:
    ///   - limit: how many of the threads that do not ask for anything are listed.
    ///   - shown: the thread on screen, which is always listed, so what is selected can be seen.
    static func derive(
        listing: ThreadListing, tasks: TasksSnapshot?, composing: Bool = false, limit: Int = pageSize, shown: String? = nil
    ) -> RailModel {
        let own = split(listing.rows, tasks: tasks, shown: shown)
        let (visible, hidden) = limited(own, limit: limit, shown: shown)
        return RailModel(
            composing: composing ? composingRow : nil, threads: visible.map(RailRow.thread), hidden: hidden, older: listing.older,
            tasks: tasks?.entries.map(RailRow.task) ?? [], tasksRead: tasks != nil)
    }

    /// A thread that asks for something of the person, or is working, or is broken: listed whatever its age.
    static func isPinned(_ row: ThreadRow) -> Bool { row.mark == .needsYou || row.mark == .working || row.mark == .broken }

    /// At most `limit` rows: the one on screen first, then the pinned ones, then the newest of the rest; listed newest first.
    static func limited(_ rows: [ThreadRow], limit: Int, shown: String?) -> (rows: [ThreadRow], hidden: Int) {
        let order = rows.filter { $0.id == shown } + rows.filter { $0.id != shown && isPinned($0) }
            + rows.filter { $0.id != shown && !isPinned($0) }
        let kept = Set(order.prefix(max(0, limit)).map(\.id))
        let visible = rows.filter { kept.contains($0.id) }
        return (visible, rows.count - visible.count)
    }

    /// The thread's rows the rail may list: not the finished ones a task's runs made, which are reached from the task's page. A thread is
    /// a task's when a task's run log names it, so threads from before this existed qualify too. One that is working, needs you or is
    /// broken stays where it is seen, and so does the one on screen. Until the tasks are read nothing is left out.
    static func split(_ rows: [ThreadRow], tasks: TasksSnapshot?, shown: String? = nil) -> [ThreadRow] {
        guard let tasks else { return rows }
        let owned = Set(tasks.entries.flatMap { $0.runs.compactMap(\.thread) })
        return rows.filter { row in
            !(owned.contains(row.id) && (row.mark == .done || row.mark == .idle) && row.id != shown)
        }
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
