import Foundation

/// Which tasks a timer should run now.
public enum TaskTick {
    /// The tasks whose next due time has passed, the earliest first. Only a task that was approved, or has run, has a time to count
    /// from, so a task nobody approved never fires. A task whose approval went stale is still due: running it records
    /// `stale-approval`, which is how a person finds out.
    public static func due(project: Project, now: Date = Date(), calendar: Calendar = .current) -> [String] {
        plan(project: project, now: now, calendar: calendar).due
    }

    /// A task that was approved once and can no longer be loaded (its script was deleted, its skill grew past the limit): with
    /// no schedule to read it cannot be called due, but it must not stop silently either.
    public struct Broken: Equatable, Sendable {
        public var name: String
        public var reason: String
    }

    public struct Plan: Equatable, Sendable {
        public var due: [String]
        public var broken: [Broken]
    }

    public static func plan(project: Project, now: Date = Date(), calendar: Calendar = .current) -> Plan {
        let library = TaskLibrary(project: project)
        var due: [(name: String, at: Date)] = []
        var broken: [Broken] = []
        for name in library.names() {
            let history = try? TaskRunLog(project: project, name: name).history()
            let loaded: LoadedTask
            do { loaded = try library.load(name) } catch {
                if history?.approvedHash != nil { broken.append(Broken(name: name, reason: "\(error)")) }
                continue
            }
            guard let schedule = loaded.definition.schedule, let history,
                let base = history.scheduleBase, let next = schedule.nextDue(since: base, calendar: calendar), next <= now
            else { continue }
            due.append((name, next))
        }
        return Plan(due: due.sorted { ($0.at, $0.name) < ($1.at, $1.name) }.map(\.name), broken: broken)
    }
}
