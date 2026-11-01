import Foundation
import WorkbenchCore

/// What the status item says: a count only while something needs you, amber for a decision and red when something broke.
struct MenuBarLabelModel: Equatable {
    var total: Int
    var tone: TaskTone?

    static func make(items: [AttentionItem]) -> MenuBarLabelModel {
        guard !items.isEmpty else { return MenuBarLabelModel(total: 0, tone: nil) }
        return MenuBarLabelModel(total: items.count, tone: items.contains { $0.tone == .broken } ? .broken : .needsYou)
    }

    var accessibility: String {
        total == 0 ? "Workbench" : "Workbench, \(total) \(total == 1 ? "thing needs" : "things need") you"
    }
}

/// One row of the popover: what needs you, in a line, and where `Open` goes.
struct PopoverRow: Equatable, Identifiable {
    var item: AttentionItem
    var detail: String
    /// `Criteria assessed 1 of 4`, for a thread in review.
    var criteria: String?
    /// The thread is in review, so `Send back…` has a card to open.
    var canSendBack: Bool
    var id: String { item.id }
}

/// What the popover shows, derived from the same store as the window so the two cannot disagree. Pure.
struct MenuBarPopoverModel: Equatable {
    enum Status: Equatable {
        case noProject
        case opening(String)
        /// The project's log cannot be read: red, with the core's words.
        case broken(String)
        /// Work is going on and nothing needs you: blue.
        case working(String)
        case nothing(String)
        case needsYou(Int)
    }

    var project: String?
    var status: Status
    var rows: [PopoverRow]
    /// Said once, when notifications are not allowed.
    var deniedNote: String?
    /// The tasks could not be read: what is listed is the last good read.
    var tasksNote: String?

    static func make(
        project: Project?, screen: ProjectScreen, items: [AttentionItem], review: ReviewModel?, denied: Bool, deniedShown: Bool,
        taskReadError: String? = nil, now: Date = Date()
    ) -> MenuBarPopoverModel {
        let name = project?.root.lastPathComponent
        let note = denied && !deniedShown
            ? "Notifications are off for Workbench: allow them in System Settings to be told when something needs you." : nil
        var rows: [PopoverRow] = []
        for item in items {
            switch item.route {
            case .thread:
                var detail = item.reason
                var criteria: String?
                if case .thread(let shown) = screen {
                    if let ended = shown.run?.endedAt {
                        detail += " " + RelativeDateTimeFormatter().localizedString(for: ended, relativeTo: now)
                    }
                    detail += " · " + shown.spendText
                    if shown.state.lastTurnEndedSeq != nil, let review { criteria = "Criteria " + review.assessed }
                }
                rows.append(PopoverRow(item: item, detail: detail, criteria: criteria, canSendBack: review != nil))
            case .task:
                let when = item.at.map { " · " + TasksText.when($0, now: now, calendar: .current) } ?? ""
                rows.append(PopoverRow(item: item, detail: item.reason + when, criteria: nil, canSendBack: false))
            }
        }
        let status: Status
        switch screen {
        case .noProject:
            status = .noProject
        case .opening(let path):
            status = .opening(URL(fileURLWithPath: path).lastPathComponent)
        case .logCorrupt(let thread, let problems):
            status = .broken("The log of \(thread) cannot be read: " + (problems.first ?? "it has damaged lines"))
        default:
            if !rows.isEmpty {
                status = .needsYou(rows.count)
            } else if case .thread(let shown) = screen, shown.attention == .working {
                status = .working(shown.title ?? shown.id)
            } else if case .thread(let shown) = screen {
                status = .nothing(shown.stateText)
            } else {
                status = .nothing(screen.message?.title ?? "")
            }
        }
        let tasksNote = taskReadError.map {
            "The tasks could not be read, so this may be out of date: \(TaskExplanation.clean($0, limit: 160))"
        }
        return MenuBarPopoverModel(project: name, status: status, rows: rows, deniedNote: note, tasksNote: tasksNote)
    }
}
