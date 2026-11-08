import Foundation

/// The top bar's Inbox / Automations switch (P26 slice 5): `WindowMode` is its state, these are its words and counts.
extension ProjectStore {
    static let inboxSegment = "inbox"
    static let automationsSegment = "automations"

    /// How many things in the open project ask for a decision: the Needs you section of its inbox, as the window reads it now.
    var inboxNeedsYou: Int {
        InboxModel.derive(listing: threads.listing, tasks: tasks.snapshot(for: project), shown: railShown).needsYou.count
    }

    /// How many automations the project has; nil until they are read.
    var automationCount: Int? { tasks.snapshot(for: project)?.entries.count }

    var switchSelection: String { mode == .tasks ? Self.automationsSegment : Self.inboxSegment }

    func switchSegments() -> [SwitchSegment] {
        let asking = inboxNeedsYou
        let automations = automationCount
        return [
            SwitchSegment(
                id: Self.inboxSegment, title: "Inbox", count: asking, tone: .amber,
                accessibility: asking == 0 ? "Inbox" : "Inbox, \(asking) need you"),
            SwitchSegment(
                id: Self.automationsSegment, title: "Automations", count: automations,
                accessibility: automations.map { "Automations, \($0)" } ?? "Automations"),
        ]
    }

    /// The Automations view shows its own list beside the task's page, so the inbox rail steps aside: four columns do not fit the 900 pt
    /// window. Not while the New task screen or the empty page is up, which have no list.
    var automationsListShown: Bool {
        guard mode == .tasks, !newThread, project != nil, !tasks.isNewShown(in: project) else { return false }
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
