import Foundation
import WorkbenchCore

extension ProjectStore {
    /// The rail now lists the inbox of every project, not the open project's own (the top tile): what the rows of the other projects are
    /// read for, on the attention poll and at once when it is chosen.
    func showAllProjects() async {
        guard !allProjects else { return }
        // The inbox of every project is an inbox: from Automations it brings the threads back, whose rail it is the list of.
        mode = .thread
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
            let open = tile.path == project?.root.path
            let rows =
                open
                ? InboxModel.rows(listing: threads.listing, entries: tasks.snapshot(for: project)?.entries, shown: railShown)
                : railSummaries.rows[tile.path] ?? []
            let older = open ? threads.listing.older : railSummaries.older[tile.path] ?? 0
            return ProjectInboxRows(path: tile.path, name: tile.name, initials: tile.initials, rows: rows, older: older)
        }
    }

    /// The arrow keys over the inbox of all projects: the row above or below the thread on screen, in the order drawn, opened without
    /// leaving the list. Nothing happens at either end or when no listed row is on screen.
    func stepAllInbox(up: Bool) async {
        let model = allInboxModel()
        guard case .thread(let snapshot) = screen, mode == .thread, !newThread, let path = project?.root.path,
            let next = InboxModel.neighbour(
                of: AllInboxModel.id(project: path, thread: snapshot.id), in: model.listed.map(\.id), up: up),
            let entry = model.listed.first(where: { $0.id == next })
        else { return }
        await open(entry, leavingList: false)
    }

    func allInboxModel() -> AllInboxModel {
        let shown = railShown.flatMap { thread in project.map { (project: $0.root.path, thread: thread) } }
        return AllInboxModel.derive(allInboxProjects(), doneOpen: allInboxDoneOpen, shown: shown)
    }

    /// A click on a row of the inbox of all projects: that project is opened (when it is not the one open), then the thread or the
    /// automation's task is shown. The rail goes back to that project's own inbox once it is open; when the project cannot be opened it
    /// says why and the list stays.
    /// - Parameter leavingList: false for the arrow keys, which step through the list and keep it up.
    func open(_ entry: AllInboxRow, leavingList: Bool = true) async {
        if entry.project != project?.root.path {
            await pickRecent(entry.project)
            guard project?.root.path == entry.project else { return }
        }
        // Opening another project goes back to its own inbox (a project tile does); a step through the list keeps this one up.
        allProjects = !leavingList
        if entry.row.isAutomation {
            selectTask(entry.row.key)
        } else {
            await select(thread: entry.row.key)
        }
    }
}
