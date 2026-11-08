import Foundation
import WorkbenchCore

extension ProjectStore {
    /// Reads the counts of the rail's projects, one after another. The open project is read too, so that its tile still has a count the
    /// moment the window moves to another; its own tile shows what the window reads of it, not this (`railBadge`). A folder that is gone
    /// is the tile's to say, and a read that fails or takes too long leaves the last count.
    func readRailSummaries() async {
        railSummaries.keep(Set(railPaths))
        for path in railPaths {
            guard Self.unavailableReason(path) == nil, railSummaries.begin(path) else { continue }
            defer { railSummaries.end(path) }
            let project = Project(root: URL(fileURLWithPath: path))
            let cache = railSummaries.cache(for: path)
            let now = Date()
            let read = await RailSummaries.raced(seconds: RailSummaries.timeout) {
                RailSummaries.read(project, cache: cache, now: now)
            }
            // A read that did not come back keeps the last count. The tasks that could not be read keep theirs too.
            guard let read, railPaths.contains(path) else { continue }
            let tasks = read.tasks ?? railSummaries.lastTasks(for: path)
            railSummaries.set(read.threads + tasks, tasks: tasks, for: path)
        }
    }

    /// What a tile shows: the window's own reading for the open project (never behind the list beside it), the last summary for the rest.
    func railBadge(for path: String) -> RailBadge {
        if path == project?.root.path { return liveBadge() }
        guard let summary = railSummaries.counts[path] else { return .none }
        return RailBadge.from(needsYou: summary.needsYou, failed: summary.failed, running: summary.running > 0)
    }

    private func liveBadge() -> RailBadge {
        let marks = threads.listing.rows.map(\.mark) + (tasks.snapshot(for: project)?.entries.map { RailRow.task($0).mark } ?? [])
        return RailBadge.from(
            needsYou: marks.filter { $0 == .needsYou }.count, failed: marks.filter { $0 == .broken }.count,
            running: marks.contains(.working))
    }
}
