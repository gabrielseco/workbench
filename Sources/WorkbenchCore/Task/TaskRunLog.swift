import Foundation

extension EventKind {
    /// The task's file (and its pending script) was approved to run unattended: `hash`.
    public static let taskApproved: EventKind = "task.approved"
    /// A run is about to begin: `trigger` (`tick` or `manual`). On record before anything is spent.
    public static let taskRunStarted: EventKind = "task.run.started"
    /// The run created its thread: `thread`, `units`. Written before the turn starts, so a run that dies after the pull request is
    /// open but before its end is written still says which units that thread was for.
    public static let taskRunThread: EventKind = "task.run.thread"
    /// The run ended, whatever came of it; exactly one per `task.run.started`: `outcome`, `reason`, `units`, `thread`.
    public static let taskRunEnded: EventKind = "task.run.ended"
}

public enum TaskOutcome: String, Sendable, Equatable {
    case prOpened = "pr-opened"
    case reported
    case nothingPending = "nothing-pending"
    case nothingToDo = "nothing-to-do"
    case skippedProjectBusy = "skipped-project-busy"
    case skippedAlreadyRunning = "skipped-already-running"
    case budgetExceeded = "budget-exceeded"
    case failed
    case staleApproval = "stale-approval"
    /// A run that never wrote its end (the process died): closed by the next one to open the log.
    case interrupted
}

/// What a task's run log says, derived on read. Nothing is stored twice (docs/spec/tasks.md).
public struct TaskHistory: Sendable, Equatable {
    public struct Run: Sendable, Equatable {
        public var started: Date
        public var trigger: String
        public var outcome: TaskOutcome?
        public var reason: String?
        public var units: [String]
        public var thread: String?
    }

    /// The hash the latest `task.approved` carries, and when.
    public var approvedHash: String?
    public var approvedAt: Date?
    public var runs: [Run] = []

    /// A run that started and has no end yet.
    public var openRun: Run? { runs.last.flatMap { $0.outcome == nil ? $0 : nil } }
    public var lastRun: Run? { runs.last }

    /// Units a run opened a pull request for, with the thread that did: they are not offered again unless that pull
    /// request was closed unmerged (see `PendingUnits`). A report run does the work of no unit.
    ///
    /// A run that died (`interrupted`) counts as well: it may have died after the pull request was open. GitHub then says whether one
    /// exists (`PendingUnits.select`).
    public var unitsWithThreads: [String: String] {
        var result: [String: String] = [:]
        for run in runs {
            guard let thread = run.thread, run.outcome == .prOpened || run.outcome == .interrupted else { continue }
            for unit in run.units { result[unit] = thread }
        }
        return result
    }

    /// Units a run recorded as having a pull request.
    public var openedUnits: Set<String> {
        Set(runs.filter { $0.outcome == .prOpened }.flatMap(\.units))
    }

    /// When the schedule counts from: the last run's start, or the approval when there was none.
    public var scheduleBase: Date? { lastRun?.started ?? approvedAt }

    init(events: [Event]) {
        for event in events {
            switch event.kind {
            case .taskApproved:
                approvedHash = event.data["hash"]?.stringValue
                approvedAt = event.date
            case .taskRunStarted:
                runs.append(
                    Run(
                        started: event.date, trigger: event.data["trigger"]?.stringValue ?? "manual", outcome: nil,
                        reason: nil, units: [], thread: nil))
            case .taskRunThread:
                guard !runs.isEmpty, runs[runs.count - 1].outcome == nil else { continue }
                runs[runs.count - 1].thread = event.data["thread"]?.stringValue
                runs[runs.count - 1].units = event.data["units"]?.arrayItems?.compactMap(\.stringValue) ?? []
            case .taskRunEnded:
                guard !runs.isEmpty, runs[runs.count - 1].outcome == nil else { continue }
                runs[runs.count - 1].outcome = event.data["outcome"]?.stringValue.flatMap(TaskOutcome.init(rawValue:)) ?? .failed
                runs[runs.count - 1].reason = event.data["reason"]?.stringValue
                // What the thread event said stays when the end has nothing to add (a run closed as interrupted).
                let units = event.data["units"]?.arrayItems?.compactMap(\.stringValue) ?? []
                if !units.isEmpty { runs[runs.count - 1].units = units }
                if let thread = event.data["thread"]?.stringValue { runs[runs.count - 1].thread = thread }
            default:
                break
            }
        }
    }
}

/// One task's run log: `tasks/<name>/runs.jsonl`, one writer, `seq` without gaps, the same file rules as a thread's log.
public struct TaskRunLog: Sendable {
    public let project: Project
    public let name: String

    public init(project: Project, name: String) {
        self.project = project
        self.name = name
    }

    public var url: URL { project.taskRunsURL(name) }

    /// Reads the log without taking the writer's lock. An absent file is an empty history.
    public func history() throws -> TaskHistory {
        guard FileManager.default.fileExists(atPath: url.path) else { return TaskHistory(events: []) }
        let contents = try EventLogReader.read(at: url)
        guard contents.problems.isEmpty else { throw EventLogError.corrupt(contents.problems) }
        return TaskHistory(events: contents.events)
    }

    /// Opens the single writer. A run the last writer left open is closed as `interrupted` first, so every start
    /// has its end ("a run always ends and says how").
    public func openWriter(now: @escaping @Sendable () -> Date = { Date() }) async throws -> EventLogWriter {
        let writer = try EventLogWriter.open(at: url, now: now)
        if let open = try history().openRun {
            _ = open
            try await writer.append(
                .taskRunEnded,
                data: [
                    "outcome": .string(TaskOutcome.interrupted.rawValue), "reason": "the run did not write its end",
                    "units": [],
                ])
        }
        return writer
    }
}

extension JSONValue {
    var arrayItems: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }
}

extension Event {
    /// `ts` as a date; the epoch when it does not parse, which makes a damaged line look old, never in the future.
    var date: Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: ts) ?? Date(timeIntervalSince1970: 0)
    }
}
