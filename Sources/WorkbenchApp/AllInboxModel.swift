import Foundation

/// A project's rows for the inbox of all projects: who they belong to, as the rail names it.
struct ProjectInboxRows: Equatable {
    var path: String
    var name: String
    var initials: String
    var rows: [InboxRow]
    /// How many older threads the listing left out (past what the app loads): rows that exist and are not here.
    var older = 0
}

/// A row of the inbox of all projects: the row, and the project it is in.
struct AllInboxRow: Equatable, Identifiable {
    var project: ProjectInboxRows.ID
    var name: String
    var initials: String
    var row: InboxRow

    var id: String { project + "|" + row.id }
    var accessibility: String { "\(row.accessibility), in \(name)" }
}

extension ProjectInboxRows: Identifiable { var id: String { path } }

/// The inbox of every project on the rail (P26 slice 4b): the same three sections as one project's, with the rows of all of them. Within a
/// section the projects keep the rail's order and each its own order (newest first), so the list is stable between reads. Pure.
struct AllInboxModel: Equatable {
    var needsYou: [AllInboxRow]
    var waiting: [AllInboxRow]
    /// The finished threads listed now: all of them when Done is open, else only the one on screen.
    var done: [AllInboxRow]
    var doneHidden: Int
    /// How many older threads of all the projects are not listed, said under the list.
    var older = 0

    /// - Parameter shown: the thread on screen and its project, listed whatever its section, so what is selected can be seen.
    static func derive(
        _ projects: [ProjectInboxRows], doneOpen: Bool, shown: (project: String, thread: String)? = nil
    ) -> AllInboxModel {
        var sections: [InboxSection: [AllInboxRow]] = [:]
        for project in projects {
            for row in project.rows {
                let entry = AllInboxRow(project: project.path, name: project.name, initials: project.initials, row: row)
                sections[InboxSection.of(row), default: []].append(entry)
            }
        }
        let finished = sections[.done] ?? []
        let listed = doneOpen ? finished : finished.filter { isShown($0, shown) }
        return AllInboxModel(
            needsYou: sections[.needsYou] ?? [], waiting: sections[.waiting] ?? [], done: listed,
            doneHidden: finished.count - listed.count, older: projects.reduce(0) { $0 + $1.older })
    }

    private static func isShown(_ entry: AllInboxRow, _ shown: (project: String, thread: String)?) -> Bool {
        guard let shown else { return false }
        return entry.row.kind == .thread && entry.project == shown.project && entry.row.key == shown.thread
    }

    /// Every row listed, in the order they are drawn.
    var listed: [AllInboxRow] { needsYou + waiting + done }

    /// The id the arrow keys start from: the thread on screen, in its project.
    static func id(project: String, thread: String) -> String { project + "|" + InboxRow.thread(thread) }

    var finishedCount: Int { done.count + doneHidden }
    var isEmpty: Bool { needsYou.isEmpty && waiting.isEmpty && finishedCount == 0 }
}
