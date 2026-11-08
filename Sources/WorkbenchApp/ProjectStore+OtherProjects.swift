import Foundation
import WorkbenchCore

extension ProjectStore {
    /// Asks GitHub about the shipped pull requests of the rail's other projects, one after another, so a tile and the inbox of all
    /// projects count what GitHub says and not what the logs said when the project was last open. It never runs two at once, lists a project
    /// only once in `otherListInterval`, asks about a thread only once in `pullRequestInterval`, and a read that fails leaves nothing.
    func readOtherProjectsPullRequests() async {
        guard !threads.readingOthers else { return }
        threads.readingOthers = true
        defer { threads.readingOthers = false }
        let model = threads
        for path in railPaths where path != project?.root.path {
            guard railPaths.contains(path) else { continue }
            if let listed = model.otherListedAt[path], listed.duration(to: .now) < model.otherListEvery { continue }
            model.otherListedAt[path] = .now
            await readPullRequests(ofProjectAt: path)
        }
    }

    private func readPullRequests(ofProjectAt path: String) async {
        let other = Project(root: URL(fileURLWithPath: path))
        let model = threads
        let summaries = railSummaries
        let cache = summaries.discoveryCache(for: path)
        // Listed from the logs alone and as far as the counts reach: a thread GitHub said closed is asked about again (it may be reopened),
        // and none that the tile counts is left out. Bounded like the rail's own reads, so a folder that hangs holds this pass for
        // `RailSummaries.timeout`, not for good.
        // Released when the read has really finished, not when this pass gave up on it: a folder that hangs holds one worker.
        let key = "github:" + path
        guard summaries.begin(key) else { return }
        let work: @Sendable () -> ThreadListing? = {
            guard ProjectStore.unavailableReason(path) == nil else { return nil }
            return ThreadListLoader.load(project: other, cache: cache, limit: ProjectSummaryLoader.maxThreads)
        }
        let listed = await RailSummaries.raced(
            seconds: RailSummaries.timeout, finished: { Task { @MainActor in summaries.end(key) } }, work)
        // An answer in time ends the hold now; one that did not come keeps it until `finished` runs.
        if listed != nil { summaries.end(key) }
        guard let listed, let listing = listed else { return }
        var changed = false
        // A merge that could not be written the last time (the log was held) is written now.
        for (thread, status) in model.unwrittenMerges(for: path) {
            changed = await recordMerge(status, thread: thread, inProjectAt: path, project: other) || changed
        }
        for row in listing.rows where row.pullRequest != nil {
            let readAt = model.readAt(row.id, for: path)
            if let readAt, readAt.duration(to: .now) < model.otherAskEvery { continue }
            // The project may have become the open one, or left the rail, while an earlier thread was asked about.
            guard path != project?.root.path, railPaths.contains(path) else { return }
            let read = try? await actions.pullRequestStatus(other, row.id)
            guard path != project?.root.path, railPaths.contains(path) else { return }
            model.record(read, thread: row.id, for: path)
            changed = true
            if let read, read.state == .merged {
                _ = await recordMerge(read, thread: row.id, inProjectAt: path, project: other)
            }
        }
        if changed { await readRailSummaries() }
    }

    /// Writes `pr.merged` for a thread of a project that is not open; a write that failed is kept and tried again on the next pass.
    private func recordMerge(_ status: PRStatus, thread: String, inProjectAt path: String, project other: Project) async -> Bool {
        guard let git = try? GitRunner.discover() else { return false }
        let result = await ThreadService(project: other, git: git).recordMerge(id: thread, status: status)
        threads.setUnwrittenMerge(result == .failed ? status : nil, thread: thread, for: path)
        return true
    }
}
