import Foundation

/// The thread list (P22 slice 5): which thread the window shows is the person's pick, else the active one, else the newest.
extension ProjectStore {
    /// Shows `id`: its session, its feed and its settings. Nothing is started, stopped or abandoned by looking at a thread.
    func select(thread id: String) async {
        // Choosing a thread in the rail leaves a task that was shown, and the new-thread screen.
        mode = .thread
        newThread = false
        // Compared with the pick still loading as well: a click back on the thread on screen cancels a click on another.
        guard project != nil, id != selectedThread || id != currentThread else { return }
        selectedThread = id
        lastWatch = nil
        await reload()
    }

    /// A thread was just made (a quick goal, a draft, a chat): with the preview on it is what the rail shows next, even when a task was on
    /// screen. Without the preview the window is as it always was.
    func showCreatedThread() {
        if chatFeedOn {
            mode = .thread
            newThread = false
        }
    }

    /// Shows the Tasks page itself (the empty one, which says where tasks are made): the rail has no switch to reach it by, and a project with no
    /// task has no row to choose.
    func showTasks() {
        mode = .tasks
        newThread = false
    }

    /// Shows a scheduled task in the main area (the rail's Scheduled section): the thread stays loaded behind it.
    func selectTask(_ name: String) {
        tasks.selection = name
        mode = .tasks
        newThread = false
    }

    /// Reads the list again, off the main actor, when the chat feed preview is on and something in it moved (or `force`).
    func refreshThreadList(force: Bool = false) async {
        guard chatFeedOn, let project else {
            (threads.listing, threads.signature) = (ThreadListing(), nil)
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
