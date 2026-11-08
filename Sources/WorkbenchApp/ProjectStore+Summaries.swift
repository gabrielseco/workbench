import Foundation
import WorkbenchCore

extension ProjectStore {
    /// Reads the counts of the rail's projects, one after another. The open project is read too, so that its tile still has a count the
    /// moment the window moves to another; its own tile shows what the window reads of it, not this (`railBadge`). A folder that is gone
    /// is the tile's to say, and a read that fails or takes too long leaves the last count.
    func readRailSummaries() async {
        railSummaries.keep(Set(railPaths))
        let summaries = railSummaries
        let wantRows = allProjects
        for path in railPaths where summaries.begin(path) {
            let project = Project(root: URL(fileURLWithPath: path))
            let cache = summaries.cache(for: path)
            let listCache = wantRows ? summaries.listCache(for: path) : nil
            let now = Date()
            // The read is released when it has really finished, not when the poll gave up on it: a read that hangs holds one worker, however
            // many polls pass.
            let read = await RailSummaries.raced(
                seconds: RailSummaries.timeout, finished: { Task { @MainActor in summaries.end(path) } },
                { RailSummaries.read(project, cache: cache, listCache: listCache, now: now) })
            // A read that did not come back, or could not list the folder, keeps the last count.
            guard let read, railPaths.contains(path) else { continue }
            if read.unavailable {
                summaries.forget(path)
                continue
            }
            guard let threads = read.threads else { continue }
            let tasks = read.tasks ?? summaries.lastTasks(for: path)
            summaries.set(threads + tasks, tasks: tasks, for: path)
            summaries.keepRows(from: read, for: path)
        }
    }

    /// The open project's counts as the window reads them now, kept for its tile when the window moves to another project.
    func captureLiveCounts() {
        guard let path = project?.root.path, railPaths.contains(path) else { return }
        railSummaries.setCounts(railCounts(for: path), for: path)
    }

    /// What a tile counts: the window's own reading for the open project (never behind the list beside it), the last summary for the rest.
    func railCounts(for path: String) -> ProjectSummary {
        guard path == project?.root.path else { return railSummaries.counts[path] ?? ProjectSummary() }
        let marks = threads.listing.rows.map(\.mark) + (tasks.snapshot(for: project)?.entries.map { RailRow.task($0).mark } ?? [])
        return ProjectSummary(
            needsYou: marks.filter { $0 == .needsYou }.count, failed: marks.filter { $0 == .broken }.count,
            running: marks.filter { $0 == .working }.count)
    }

    func railBadge(for path: String) -> RailBadge { Self.badge(railCounts(for: path)) }

    /// The top tile: every project of the rail together, as the artboard has it, the number of things that need you in amber. A failure is
    /// on its own project's tile; it takes the top tile only when nothing asks for a decision, so four that need you are never hidden by one
    /// that failed.
    func allProjectsBadge() -> RailBadge {
        let total = railPaths.reduce(ProjectSummary()) { $0 + railCounts(for: $1) }
        if total.needsYou > 0 { return .needsYou(total.needsYou) }
        return Self.badge(total)
    }

    private static func badge(_ counts: ProjectSummary) -> RailBadge {
        RailBadge.from(needsYou: counts.needsYou, failed: counts.failed, running: counts.running > 0)
    }
}
