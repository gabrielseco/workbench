import Foundation
import Observation
import WorkbenchCore

/// What the rail's tiles count for the projects that are not open (P26 slice 3): read on the attention poll, one project after another,
/// never written, and kept when a read fails so a count does not drop to zero on a hiccup.
@MainActor @Observable final class RailSummaries {
    /// The last count read for each project, threads and tasks together.
    private(set) var counts: [String: ProjectSummary] = [:]
    @ObservationIgnored private var caches: [String: ProjectSummaryLoader.Cache] = [:]
    /// The tasks' part of each count as last read, used again when the tasks cannot be read this time.
    @ObservationIgnored private var lastTasks: [String: ProjectSummary] = [:]
    /// Projects whose read has not come back: asked again only when it has, so a hung folder holds one thread, not one a poll.
    @ObservationIgnored private var reading: Set<String> = []

    /// How long one project's read may take before the poll goes on without it.
    static let timeout: TimeInterval = 10

    func cache(for path: String) -> ProjectSummaryLoader.Cache {
        if let known = caches[path] { return known }
        let fresh = ProjectSummaryLoader.Cache()
        caches[path] = fresh
        return fresh
    }

    func begin(_ path: String) -> Bool { reading.insert(path).inserted }
    /// Called when the read itself has finished, which may be long after the poll gave up on it.
    func end(_ path: String) { reading.remove(path) }

    func set(_ summary: ProjectSummary, tasks: ProjectSummary, for path: String) {
        lastTasks[path] = tasks
        counts[path] = summary
    }

    func lastTasks(for path: String) -> ProjectSummary { lastTasks[path] ?? ProjectSummary() }

    /// A project whose folder is gone has no count: its tile says so.
    func forget(_ path: String) {
        counts[path] = nil
        lastTasks[path] = nil
    }

    /// Forgets what a project that is no longer on the rail (or is gone) had.
    func keep(_ paths: Set<String>) {
        counts = counts.filter { paths.contains($0.key) }
        caches = caches.filter { paths.contains($0.key) }
        lastTasks = lastTasks.filter { paths.contains($0.key) }
    }

    /// What the tasks of a project add to its count, by the rules the rail's rows apply: a task that needs you, one that failed, one running.
    nonisolated static func tasks(_ entries: [TaskEntry]) -> ProjectSummary {
        var summary = ProjectSummary()
        for entry in entries {
            switch RailRow.task(entry).mark {
            case .needsYou: summary.add(.needsYou)
            case .broken: summary.add(.broken)
            case .working: summary.add(.working)
            case .done, .idle: break
            }
        }
        return summary
    }

    /// One project's read: its threads, and its tasks (nil when they could not be read). Off the main actor, writes nothing.
    struct Read: Sendable {
        /// The project's folder cannot be opened now: the tile says so, and nothing is counted.
        var unavailable = false
        /// nil when the threads folder could not be listed: the last count stands.
        var threads: ProjectSummary?
        /// nil when the tasks could not be read: their last part stands.
        var tasks: ProjectSummary?
    }

    /// The availability check is part of the read: it touches the same folder, so it is under the same limit.
    nonisolated static func read(_ project: Project, cache: ProjectSummaryLoader.Cache, now: Date) -> Read {
        if ProjectStore.unavailableReason(project.root.path) != nil { return Read(unavailable: true) }
        return Read(
            threads: ProjectSummaryLoader.read(project: project, cache: cache),
            tasks: (try? TasksReader.entries(project, now: now)).map(tasks))
    }

    /// `work` on a background queue, its answer if it comes within `seconds`, else nil: a folder that hangs (a network volume that went away)
    /// cannot hold the poll. The work itself cannot be stopped, so it is left to finish by itself.
    /// `finished` is called when the work really ends, answer used or not.
    nonisolated static func raced<T: Sendable>(
        seconds: TimeInterval, finished: @escaping @Sendable () -> Void = {}, _ work: @escaping @Sendable () -> T
    ) async -> T? {
        await withCheckedContinuation { continuation in
            let once = Once()
            DispatchQueue.global(qos: .utility).async {
                let value = work()
                finished()
                if once.first() { continuation.resume(returning: value) }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) {
                if once.first() { continuation.resume(returning: nil) }
            }
        }
    }

    /// True for the first caller only.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var taken = false
        func first() -> Bool { lock.withLock { taken ? false : { taken = true; return true }() } }
    }
}
