import Foundation

/// A project's rows for the inbox of all projects: who they belong to, as the rail names it.
struct ProjectInboxRows: Equatable {
    var path: String
    var name: String
    var initials: String
    var rows: [InboxRow]
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
    /// The finished threads listed now: all of them when Done is open, else none (there is no one on screen across projects to keep).
    var done: [AllInboxRow]
    var doneHidden: Int

    static func derive(_ projects: [ProjectInboxRows], doneOpen: Bool) -> AllInboxModel {
        var sections: [InboxSection: [AllInboxRow]] = [:]
        for project in projects {
            for row in project.rows {
                let entry = AllInboxRow(project: project.path, name: project.name, initials: project.initials, row: row)
                sections[InboxSection.of(row), default: []].append(entry)
            }
        }
        let finished = sections[.done] ?? []
        return AllInboxModel(
            needsYou: sections[.needsYou] ?? [], waiting: sections[.waiting] ?? [], done: doneOpen ? finished : [],
            doneHidden: doneOpen ? 0 : finished.count)
    }

    var finishedCount: Int { done.count + doneHidden }
    var isEmpty: Bool { needsYou.isEmpty && waiting.isEmpty && finishedCount == 0 }
}
