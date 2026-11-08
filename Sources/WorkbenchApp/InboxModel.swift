import Foundation

/// One row of the inbox: a thread or an automation that asks for approval, said the same way: the mark, the title, the reason in words and
/// what it has cost. An automation carries the `auto` tag.
struct InboxRow: Equatable, Identifiable {
    enum Kind: String, Equatable { case thread, automation }

    var kind: Kind
    /// The thread's id, or the task's name.
    var key: String
    var title: String
    var mark: ThreadMark
    var line: String
    var spend: String?

    var id: String { "\(kind.rawValue)-\(key)" }
    var isAutomation: Bool { kind == .automation }
    var help: String { "\(title): \(line)" }
    var accessibility: String { "\(title), \(mark.word), \(line)" + (isAutomation ? ", automation" : "") }

    init(thread row: ThreadRow) {
        (kind, key, title, mark, line, spend) = (.thread, row.id, row.title, row.mark, row.line, row.spend)
    }

    init(automation row: RailRow) {
        (kind, key, title, mark, line, spend) = (.automation, row.key, row.title, row.mark, row.line, nil)
    }
}

/// The three sections of the inbox, in the order they are drawn (P26): what needs you first, then what waits on something else, then what is over.
enum InboxSection: String, CaseIterable, Equatable {
    case needsYou, waiting, done

    var title: String {
        switch self {
        case .needsYou: "NEEDS YOU"
        case .waiting: "WAITING"
        case .done: "DONE"
        }
    }

    /// The section a thread's row belongs to, and only one: a thread that asks for something (or is broken) needs you; one that is over is
    /// done; the rest, working or drafting or with a pull request open, waits.
    static func of(_ row: ThreadRow) -> InboxSection {
        if row.mark == .needsYou || row.mark == .broken { return .needsYou }
        return row.finished ? .done : .waiting
    }
}

/// What the project's inbox lists: the threads sorted into sections by what they ask of the person, and the automations that need approval
/// among the ones that need you. Pure, so the sections are tested without a window.
struct InboxModel: Equatable {
    /// The thread being started on the new-thread screen: a row of its own at the top, selected, until something is chosen.
    var composing: RailRow?
    var needsYou: [InboxRow]
    var waiting: [InboxRow]
    /// The finished threads listed now: all of them when the section is open, else only the one on screen (so what is selected is seen).
    var done: [InboxRow]
    /// How many finished threads the collapsed section keeps out of the list: what `Show N finished threads` would add.
    var doneHidden: Int
    /// How many older threads the listing itself left out (past the loader's cap).
    var older: Int

    static let composingRow = RailRow(
        kind: .thread, key: "new-thread", title: "New thread", mark: .idle, line: "Type to start · free")

    /// - Parameters:
    ///   - doneOpen: the Done section is open: every finished thread is listed.
    ///   - shown: the thread on screen, which is always listed, so what is selected can be seen.
    static func derive(
        listing: ThreadListing, tasks: TasksSnapshot?, composing: Bool = false, shown: String? = nil, doneOpen: Bool = false
    ) -> InboxModel {
        let rows = split(listing.rows, tasks: tasks, shown: shown)
        let sorted = Dictionary(grouping: rows, by: InboxSection.of)
        let finished = (sorted[.done] ?? []).map(InboxRow.init(thread:))
        let listed = doneOpen ? finished : finished.filter { $0.key == shown }
        // An automation that waits for approval is something to decide, so it is among the ones that need you (after the threads).
        let automations = (tasks?.entries.map(RailRow.task) ?? []).filter { $0.mark == .needsYou }.map(InboxRow.init(automation:))
        return InboxModel(
            composing: composing ? composingRow : nil,
            needsYou: (sorted[.needsYou] ?? []).map(InboxRow.init(thread:)) + automations,
            waiting: (sorted[.waiting] ?? []).map(InboxRow.init(thread:)), done: listed,
            doneHidden: finished.count - listed.count, older: listing.older)
    }

    /// The thread's rows the inbox may list: not the finished ones a task's runs made, which are reached from the task's page. A thread is a
    /// task's when a task's run log names it, so threads from before this existed qualify too. One that is working, needs you or is broken
    /// stays where it is seen, and so does the one on screen. Until the tasks are read nothing is left out.
    static func split(_ rows: [ThreadRow], tasks: TasksSnapshot?, shown: String? = nil) -> [ThreadRow] {
        guard let tasks else { return rows }
        let owned = Set(tasks.entries.flatMap { $0.runs.compactMap(\.thread) })
        return rows.filter { row in
            !(owned.contains(row.id) && (row.mark == .done || row.mark == .idle) && row.id != shown)
        }
    }

    /// Every row listed, in the order they are drawn.
    var listed: [InboxRow] { needsYou + waiting + done }

    /// The threads among them (the arrow keys move over these and the tasks, an automation row opening its task).
    var threadRows: [InboxRow] { listed.filter { !$0.isAutomation } }

    /// How many finished threads there are in all, listed or not.
    var finishedCount: Int { done.count + doneHidden }

    /// What the "N older threads" line says when it is hovered: they are past what the app loads, and the command that lists them.
    static func olderHelp(_ older: Int) -> String {
        let subject = older == 1 ? "1 older thread is" : "\(older) older threads are"
        return "\(subject) past the 50 the app loads. `workbench status --all` lists them, `workbench log <id>` shows one."
    }

    /// What the arrow keys walk, in the order it is drawn: the inbox's rows (an automation among them is a task), then the Scheduled
    /// tasks the inbox does not already show. A task is one stop wherever it is drawn, so a press never lands where it started.
    func navigation(scheduled: [String]) -> [String] {
        let inInbox = Set(listed.filter(\.isAutomation).map(\.key))
        let drawn = listed.map { ($0.isAutomation ? "k:" : "t:") + $0.key }
        return drawn + scheduled.filter { !inInbox.contains($0) }.map { "s:" + $0 }
    }

    /// The stop the window's screen is on: the thread's, or the task's (at its row in the inbox when it has one, else in Scheduled).
    func navigationID(thread: String?, task: String?) -> String? {
        if let task { return listed.contains { $0.isAutomation && $0.key == task } ? "k:" + task : "s:" + task }
        return thread.map { "t:" + $0 }
    }

    /// The row above or below the one shown, for the arrow keys; nil at either end or when none is shown.
    static func neighbour(of shown: String?, in ids: [String], up: Bool) -> String? {
        guard let at = shown.flatMap({ ids.firstIndex(of: $0) }) else { return nil }
        let next = up ? at - 1 : at + 1
        return ids.indices.contains(next) ? ids[next] : nil
    }
}
