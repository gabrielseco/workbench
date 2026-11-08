import Foundation
import WorkbenchCore

extension ProjectStore {
    /// The rail now lists the inbox of every project, not the open project's own (the top tile): what the rows of the other projects are
    /// read for, on the attention poll and at once when it is chosen.
    func showAllProjects() async {
        guard !allProjects else { return }
        allProjects = true
        await readRailSummaries()
    }

    /// Back to the open project's own inbox.
    func leaveAllProjects() { allProjects = false }

    func toggleAllDoneOpen() { allInboxDoneOpen.toggle() }

    /// The rows of the rail's projects, in the rail's order: the open project's as the window reads them now, the others' as last read.
    /// A project whose folder is gone has none.
    func allInboxProjects() -> [ProjectInboxRows] {
        railTiles().filter { $0.unavailable == nil }.map { tile in
            let rows =
                tile.path == project?.root.path
                ? InboxModel.rows(listing: threads.listing, entries: tasks.snapshot(for: project)?.entries, shown: railShown)
                : railSummaries.rows[tile.path] ?? []
            return ProjectInboxRows(path: tile.path, name: tile.name, initials: tile.initials, rows: rows)
        }
    }

    func allInboxModel() -> AllInboxModel {
        let shown = railShown.flatMap { thread in project.map { (project: $0.root.path, thread: thread) } }
        return AllInboxModel.derive(allInboxProjects(), doneOpen: allInboxDoneOpen, shown: shown)
    }

    /// A click on a row of the inbox of all projects: that project is opened (when it is not the one open), then the thread or the
    /// automation's task is shown. The rail goes back to that project's own inbox once it is open; when the project cannot be opened it
    /// says why and the list stays.
    func open(_ entry: AllInboxRow) async {
        if entry.project != project?.root.path {
            await pickRecent(entry.project)
            guard project?.root.path == entry.project else { return }
        }
        allProjects = false
        if entry.row.isAutomation {
            selectTask(entry.row.key)
        } else {
            await select(thread: entry.row.key)
        }
    }
}
