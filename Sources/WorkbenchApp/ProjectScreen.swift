import Foundation
import WorkbenchCore

/// What the window shows. One case per way a project can be unusable, each with what to do next, so no state is a blank.
enum ProjectScreen: Equatable {
    case noProject
    case notAGitRepository(path: String)
    case workbenchMissing(path: String)
    case noThread
    case logCorrupt(thread: String, problems: [String])
    case thread(ThreadSnapshot)

    /// What went wrong, for the empty and error states; nil for a thread.
    var message: (title: String, next: String)? {
        switch self {
        case .noProject:
            ("No project chosen", "Choose the folder of a git repository that Workbench works on.")
        case .notAGitRepository(let path):
            ("Not a git repository", "\(path) is not inside a git repository. Choose the repository's folder.")
        case .workbenchMissing(let path):
            (
                "This project has no .workbench folder",
                "Run `workbench init` in \(path), then choose it again."
            )
        case .noThread:
            ("No thread yet", "Start one with New goal, or in a terminal: workbench goal new <name>.")
        case .logCorrupt(let thread, let problems):
            (
                "The log of \(thread) cannot be read",
                (problems.first ?? "It has damaged lines") + ". Open the event log to see it; Workbench never rewrites it."
            )
        case .thread:
            nil
        }
    }
}

/// Everything the window shows about one thread, derived from its log and goal file. Nothing here is stored twice.
struct ThreadSnapshot: Equatable {
    var id: String
    var title: String?
    var base: String?
    var approval: ApprovalState?
    var budgetUSD: Decimal?
    var turnTimeoutMin: Int?
    var state: ThreadState
    var spine: ThreadSpine
    var attention: Attention
    /// The `seq` of the last event, what the footer's `Event log` chip counts.
    var lastSeq: Int
    var logURL: URL
    /// What is damaged in a log that still shows something (a line that is not an event, a break in the sequence), in words
    /// a person can act on. The thread shows what could be read, never as if the log were whole.
    var problems: [String] = []
    /// The latest turn as the Run screen shows it; nil before the first turn.
    var run: RunModel?

    /// How a decided thread ended, in words; nil while it is still open.
    var finishedText: String? {
        if state.cleaned { return "Cleaned: the branch was removed." }
        if let pr = state.pullRequest { return "Shipped as PR #\(pr.number)." }
        switch state.decision {
        case "accepted": return "Accepted, not shipped yet."
        case "discarded": return "Discarded: the worktree and branch were removed."
        case "abandoned": return "Abandoned."
        case let other?: return other.capitalized + "."
        case nil: return nil
        }
    }

    /// Why `New goal…` is not offered yet; nil when it is. Work that was accepted keeps the window until it is cleaned or
    /// abandoned, so its shipping context is not left behind (docs/plan/P19-swiftui-app.md, open decision 1).
    var newGoalHint: String? {
        guard state.decision != nil, !state.cleaned else { return nil }
        if state.pullRequest != nil {
            return "Clean this thread once its pull request is merged, then start the next goal."
        }
        if state.decision == "accepted" { return "Ship this thread first (`workbench ship`), or abandon it, then start the next goal." }
        return nil
    }

    /// The cost as the toolbar says it: `unknown` when a turn reported none, never `$0.00`.
    var spendText: String {
        let spent = state.knownCostUSD.map { String(format: "$%.2f", $0) } ?? "unknown"
        guard let budget = budgetUSD else { return spent }
        return "\(spent) of \(String(format: "$%.2f", NSDecimalNumber(decimal: budget).doubleValue))"
    }

    /// The state pill: one word for where the thread stands for the person.
    var stateText: String {
        if case .needsYou(let reason) = attention { return "Needs you · \(reason.text)" }
        if attention == .working { return "Working" }
        if let decision = state.decision { return decision.capitalized }
        if approval != .approved && state.lastTurn == 0 { return "Draft · not approved" }
        return "Waiting"
    }
}
