import AppKit
import SwiftUI
import WorkbenchCore

/// What the task page says, derived from what the window already reads (design parity 5). Pure, so each rule is tested without a window.
enum TaskPage {
    struct Header: Equatable {
        /// `weekdays 04:00 · opens a PR · 13 runs · next tomorrow 04:00`
        var line: String
        /// Where the task is defined: the file is the source, and the page says so.
        var path: String
    }

    static func header(_ entry: TaskEntry, now: Date) -> Header {
        let summary = entry.summary
        let fix = summary.fix == .pr ? "opens a PR" : "reports"
        let runs = "\(entry.runs.count) run\(entry.runs.count == 1 ? "" : "s")"
        return Header(
            line: "\(summary.schedule ?? "manual") · \(fix) · \(runs) · next \(TasksText.next(summary, now: now))",
            path: ".workbench/tasks/\(summary.name)/task.md")
    }
}

/// "Will it run tonight?" for one task: a verdict and the warnings behind it, worst first.
struct RunTonight: Equatable {
    enum Verdict: Equatable {
        case willRun, checkWarnings, willNotRun

        var text: String {
            switch self {
            case .willRun: "Will run"
            case .checkWarnings: "Will run, check the warnings"
            case .willNotRun: "Will not run"
            }
        }
    }

    enum Action: Equatable {
        case approve, reapprove
        case openThread(String)
    }

    struct Warning: Equatable {
        var fails: Bool
        var text: String
        /// A command or a thread id under the text.
        var detail: String?
        var action: Action?
    }

    var verdict: Verdict
    var warnings: [Warning]

    /// Open when there is something to read; one line when there is not.
    var openByDefault: Bool { !warnings.isEmpty }
    var countText: String? {
        warnings.isEmpty ? nil : "\(warnings.count) warning\(warnings.count == 1 ? "" : "s")"
    }

    /// The task's own reasons first (a file that does not load, an approval missing or stale, a last run that waited for review), then the
    /// project's (another thread is still active, so the next run would skip), then the machine's (the timer's lines that warn or fail).
    /// Anything that stops it running is a problem and listed before what only needs a look.
    static func derive(_ entry: TaskEntry, timer: TimerCard, activeThread: String?) -> RunTonight {
        let summary = entry.summary
        var found: [Warning] = []
        if let problem = summary.problem {
            let detail = TaskExplanation.clean(problem, limit: 200)
            found.append(Warning(fails: true, text: "The task does not load.", detail: detail))
        } else if summary.approval == .never {
            found.append(
                Warning(
                    fails: true, text: "Not approved: nothing runs unapproved.", detail: "workbench task approve \(summary.name)",
                    action: .approve))
        } else if summary.approval == .stale {
            found.append(
                Warning(
                    fails: true, text: "The task changed since you approved it.",
                    detail: "workbench task approve \(summary.name)", action: .reapprove))
        }
        // The timer's own line for this (`approved but has no schedule`) is one of the task lines left out below, so it is said here.
        if summary.problem == nil, summary.approval == .approved, summary.schedule == nil {
            found.append(
                Warning(
                    fails: false, text: "It has no schedule: a tick never runs it, so it runs only when you run it.",
                    detail: "workbench task run \(summary.name)"))
        }
        if let active = activeThread, !entry.isRunning {
            found.append(
                Warning(
                    fails: false, text: "An earlier thread is still active, so the next run would skip.", detail: active,
                    action: .openThread(active)))
        }
        if entry.runs.first?.outcome == .skippedTooManyOpen {
            found.append(
                Warning(fails: false, text: "It has as many pull requests open as it allows: it waits for review.", detail: nil))
        }
        switch timer {
        case .lines(let lines):
            // The timer's lines about tasks (`task cleanup-branches: not approved`, this task's own too) are each task's own reasons, which are
            // listed above from the task itself: only what is about the machine is the machine's.
            for line in lines where line.level != .ok && !line.text.hasPrefix("task ") {
                found.append(Warning(fails: line.level == .fail, text: line.text, detail: nil))
            }
        case .unknown(let why):
            found.append(Warning(fails: false, text: "The timer could not be read: \(why)", detail: nil))
        }
        let ordered = found.filter(\.fails) + found.filter { !$0.fails }
        let verdict: Verdict = ordered.contains { $0.fails } ? .willNotRun : (ordered.isEmpty ? .willRun : .checkWarnings)
        return RunTonight(verdict: verdict, warnings: ordered)
    }
}

/// A task's runs under a quiet heading for the day they started.
enum RunDay {
    struct Group: Equatable {
        var heading: String
        var runs: [TaskHistory.Run]
    }

    /// `runs` newest first, as the entry holds them; the groups keep that order.
    static func groups(runs: [TaskHistory.Run], now: Date, calendar: Calendar = .current) -> [Group] {
        var groups: [Group] = []
        for run in runs {
            let heading = heading(for: run.started, now: now, calendar: calendar)
            if groups.last?.heading == heading { groups[groups.count - 1].runs.append(run) } else {
                groups.append(Group(heading: heading, runs: [run]))
            }
        }
        return groups
    }

    static func heading(for date: Date, now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "TODAY" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "YESTERDAY"
        }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()).uppercased()
    }
}

/// The one button a run has: what deals with how it ended.
enum RunAction: Equatable {
    case viewLog
    case approve
    case reapprove
    case openThread(String)

    var title: String {
        switch self {
        case .viewLog: "View log"
        case .approve: "Approve…"
        case .reapprove: "Re-approve"
        case .openThread: "Open thread"
        }
    }

    /// A run that ended badly shows its log; a stale approval offers the approval; any other run with a thread offers the thread; a run
    /// still going, or one with nothing behind it, has none.
    static func of(_ run: TaskHistory.Run) -> RunAction? {
        guard let outcome = run.outcome else { return nil }
        switch TaskOutcomeStyle.tone(outcome) {
        case .broken: return .viewLog
        default: break
        }
        if outcome == .staleApproval { return .reapprove }
        return run.thread.map(RunAction.openThread)
    }
}
