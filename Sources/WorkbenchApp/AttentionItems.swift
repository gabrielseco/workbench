import Foundation
import WorkbenchCore

/// Where an attention item takes you.
enum AttentionRoute: Equatable, Sendable {
    case thread(String)
    case task(String)

    var encoded: String {
        switch self {
        case .thread(let id): "thread:\(id)"
        case .task(let name): "task:\(name)"
        }
    }

    init?(encoded: String) {
        if encoded.hasPrefix("thread:") { self = .thread(String(encoded.dropFirst(7))) } else if encoded.hasPrefix("task:") {
            self = .task(String(encoded.dropFirst(5)))
        } else { return nil }
    }
}

/// One thing that needs a person, with the identity a notification and a "seen" mark are kept under.
struct AttentionItem: Equatable, Identifiable {
    var id: String
    var route: AttentionRoute
    /// The thread's title or the task's name.
    var title: String
    /// Why, in one line.
    var reason: String
    /// Amber for a decision, red for something that broke.
    var tone: TaskTone
    /// When the run began, for a task's failure.
    var at: Date?
}

/// What the thread on screen says about itself.
struct ThreadAttention: Equatable {
    var id: String
    var title: String?
    var attention: Attention
    /// The pull request's CI has been asked for (or there is no pull request). Until then a CI failure cannot be seen, so a look
    /// without it is not yet the thread's baseline.
    var ciLoaded = true
}

/// Which things need a person, from the thread's `Attention` and the project's tasks. Pure: the same inputs give the same list, so a
/// notification rule can be tested by replaying snapshots.
enum AttentionItems {
    /// A run that ended in one of these broke; the others end well, or are a skip, or have not ended.
    static let broke: Set<TaskOutcome> = [.failed, .budgetExceeded, .interrupted]
    /// A skip is the next tick's problem, not yours, and says nothing about whether an earlier failure is fixed.
    static let skips: Set<TaskOutcome> = [.skippedProjectBusy, .skippedAlreadyRunning, .skippedTooManyOpen]

    static func derive(thread: ThreadAttention?, tasks: [TaskEntry]) -> [AttentionItem] {
        var items: [AttentionItem] = []
        if let thread, case .needsYou(let reason) = thread.attention {
            let commit = reason.commit.map { ":" + $0 } ?? ""
            items.append(
                AttentionItem(
                    id: "thread:\(thread.id):\(reason.since)\(commit)", route: .thread(thread.id),
                    title: thread.title ?? thread.id, reason: reason.text, tone: .needsYou, at: nil))
        }
        for entry in tasks { items += taskItems(entry) }
        return items
    }

    private static func taskItems(_ entry: TaskEntry) -> [AttentionItem] {
        let summary = entry.summary
        // A task that does not load is the timer card's problem (and says so there), not a decision waiting for you.
        guard summary.problem == nil else { return [] }
        var items: [AttentionItem] = []
        if summary.approval == .stale {
            let stamp = Int(entry.approvedAt?.timeIntervalSince1970 ?? 0)
            items.append(
                AttentionItem(
                    id: "task:\(summary.name):stale:\(stamp)", route: .task(summary.name), title: summary.name,
                    reason: "edited since it was approved, so it will not run until you approve it again", tone: .needsYou,
                    at: nil))
        }
        // The newest run that says how the task is doing: not one still going, a skip, or the stale-approval note (the approval
        // itself is read above, and a fresh approval clears it).
        let decisive = entry.runs.first { run in
            guard let outcome = run.outcome else { return false }
            return !skips.contains(outcome) && outcome != .staleApproval
        }
        if let run = decisive, let outcome = run.outcome, broke.contains(outcome) {
            let why = TasksText.reason(run).map { ": " + String($0.prefix(160)) } ?? ""
            items.append(
                AttentionItem(
                    id: "task:\(summary.name):\(Int(run.started.timeIntervalSince1970))", route: .task(summary.name),
                    title: summary.name, reason: "\(outcome.rawValue)\(why)", tone: .broken, at: run.started))
        }
        return items
    }
}
