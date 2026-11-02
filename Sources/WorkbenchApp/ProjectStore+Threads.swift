import Foundation

/// The thread list (P22 slice 5): which thread the window shows is the person's pick, else the active one, else the newest.
extension ProjectStore {
    /// Shows `id`: its session, its feed and its settings. Nothing is started, stopped or abandoned by looking at a thread.
    func select(thread id: String) async {
        guard project != nil, id != currentThread else { return }
        selectedThread = id
        lastWatch = nil
        await reload()
    }

    /// Reads the list again, off the main actor, when the chat feed preview is on and something in it moved (or `force`).
    func refreshThreadList(force: Bool = false) async {
        guard chatFeedOn, let project else {
            threads.listing = ThreadListing()
            return
        }
        let (mine, cache) = (generation, threadRowCache)
        let moved = await Task.detached { ThreadListLoader.signature(project: project) }.value
        guard mine == generation, force || moved != threads.signature else { return }
        let listing = await Task.detached { ThreadListLoader.load(project: project, cache: cache) }.value
        guard mine == generation else { return }
        threads.signature = moved
        if listing != threads.listing { threads.listing = listing }
    }
}
