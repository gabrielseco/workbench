import Foundation

/// Which tasks a timer should run now.
public enum TaskTick {
    /// The tasks whose next due time has passed, the earliest first. Only a task that was approved, or has run, has a time to count
    /// from, so a task nobody approved never fires. A task whose approval went stale is still due: running it records
    /// `stale-approval`, which is how a person finds out.
    public static func due(project: Project, now: Date = Date(), calendar: Calendar = .current) -> [String] {
        let library = TaskLibrary(project: project)
        var due: [(name: String, at: Date)] = []
        for name in library.names() {
            guard let loaded = try? library.load(name), let schedule = loaded.definition.schedule,
                let history = try? TaskRunLog(project: project, name: name).history(),
                let base = history.scheduleBase, let next = schedule.nextDue(since: base, calendar: calendar), next <= now
            else { continue }
            due.append((name, next))
        }
        return due.sorted { ($0.at, $0.name) < ($1.at, $1.name) }.map(\.name)
    }
}
