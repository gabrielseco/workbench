import Foundation

/// The top bar's Inbox / Automations switch (P26 slice 5): `WindowMode` is its state, these are its words and counts.
extension ProjectStore {
    static let inboxSegment = "inbox"
    static let automationsSegment = "automations"

    /// How many things in the open project ask for a decision: the Needs you section of its inbox, as the window reads it now.
    var inboxNeedsYou: Int {
        InboxModel.derive(listing: threads.listing, tasks: tasks.snapshot(for: project), shown: railShown).needsYou.count
    }

    /// How many automations failed or cannot run: red on the switch, as the design has it. Zero until the tasks are read.
    var automationsFailing: Int {
        tasks.snapshot(for: project)?.entries.map(RailRow.task).filter { $0.mark == .broken }.count ?? 0
    }

    /// A rail or list is being walked with the keys: a screen that opens under it must not take the caret.
    var listHasKeys: Bool { railFocused || listFocused }

    var switchSelection: String { mode == .tasks ? Self.automationsSegment : Self.inboxSegment }

    func switchSegments() -> [SwitchSegment] {
        let asking = inboxNeedsYou
        let failing = automationsFailing
        return [
            SwitchSegment(
                id: Self.inboxSegment, title: "Inbox", count: asking, fill: Theme.amber,
                accessibility: asking == 0 ? "Inbox" : "Inbox, \(asking) need you"),
            SwitchSegment(
                id: Self.automationsSegment, title: "Automations", count: failing, fill: Theme.red,
                accessibility: failing == 0 ? "Automations" : "Automations, \(failing) failed"),
        ]
    }

    /// The Automations view shows its own list beside the task's page, so the inbox rail steps aside: four columns do not fit the 900 pt
    /// window (the design has the list in the rail's place). Not while the New task screen or the empty page is up, which have no list,
    /// nor while the inbox of all projects is chosen, which is a rail.
    var automationsListShown: Bool {
        guard mode == .tasks, !newThread, !allProjects, project != nil, !tasks.isNewShown(in: project) else { return false }
        return tasks.snapshot(for: project).map { !$0.entries.isEmpty } ?? false
    }

    /// A choice in the switch: the inbox is the thread screen (what was on it stays), automations is the Tasks screen.
    func chooseSwitch(_ id: String) {
        if id == Self.automationsSegment {
            showTasks()
        } else {
            showInbox()
        }
    }

    /// Back to the threads: the one that was on screen, or the new-thread screen when that is what was open.
    func showInbox() {
        mode = .thread
        tasks.newShown = false
    }
}
