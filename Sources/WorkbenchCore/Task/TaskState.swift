import Foundation

/// What a person can do to a task's place in the schedule, without touching its file: turn the schedule off and on, or put the task
/// away and bring it back. Each is one event in the task's run log, so the state survives a restart and is derived on read
/// (`TaskHistory.enabled`, `archived`). Nothing is deleted: an archived task keeps its `task.md`, its reports and its runs.
public enum TaskStateChange: String, Sendable, Equatable, CaseIterable {
    case disable, enable, archive, restore

    var kind: EventKind {
        switch self {
        case .disable: .taskDisabled
        case .enable: .taskEnabled
        case .archive: .taskArchived
        case .restore: .taskRestored
        }
    }

    /// Whether the history is already in the state this change asks for: then nothing is written.
    func holds(in history: TaskHistory) -> Bool {
        switch self {
        case .disable: !history.enabled
        case .enable: history.enabled
        case .archive: history.archived
        case .restore: !history.archived
        }
    }
}

public enum TaskStateError: Error, Equatable, CustomStringConvertible {
    case notFound(String)
    /// A run of the task holds its log: the change waits until it ends.
    case running(String)

    public var description: String {
        switch self {
        case .notFound(let name): "no task '\(name)' (.workbench/tasks/\(name)/task.md)"
        case .running(let name): "a run of \(name) is going: try again when it has ended"
        }
    }
}

extension TaskLibrary {
    /// The tasks on the active list: every task that is not archived (a disabled one is still listed, and says so).
    public func activeNames() -> [String] {
        names().filter { (try? TaskRunLog(project: project, name: $0).history())?.archived != true }
    }

    /// The archived tasks, kept for reference.
    public func archivedNames() -> [String] {
        names().filter { (try? TaskRunLog(project: project, name: $0).history())?.archived == true }
    }

    /// Records the change unless the task is already in that state. Returns the history after it, so the caller can say the state
    /// it is in now (a restored task is enabled or disabled as it was). Refused while a run holds the log, and for a task that is not
    /// there; a task whose file does not load can still be disabled or archived.
    @discardableResult
    public func change(
        _ name: String, _ change: TaskStateChange, now: @escaping @Sendable () -> Date = { Date() }
    ) async throws -> TaskHistory {
        guard names().contains(name) else { throw TaskStateError.notFound(name) }
        let log = TaskRunLog(project: project, name: name)
        let writer: EventLogWriter
        do { writer = try await log.openWriter(now: now) } catch EventLogError.alreadyOpen {
            throw TaskStateError.running(name)
        }
        do {
            if !change.holds(in: try log.history()) { try await writer.append(change.kind, data: [:]) }
        } catch {
            await writer.close()
            throw error
        }
        await writer.close()
        return try log.history()
    }
}
