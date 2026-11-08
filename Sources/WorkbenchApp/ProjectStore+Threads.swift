import Foundation
import WorkbenchCore

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

    /// A thread was just made (a quick goal, a draft, a chat): it is what the rail shows next, even when a task was on screen.
    func showCreatedThread() {
        mode = .thread
        newThread = false
    }

    /// Shows the Tasks page itself (the empty one, which says where tasks are made): the rail has no switch to reach it by, and a project with no
    /// task has no row to choose.
    func showTasks() {
        mode = .tasks
        newThread = false
    }

    /// Opens the New task screen in the main area: the thread stays loaded behind it.
    func beginNewTask() {
        tasks.beginNew(project)
        mode = .tasks
        newThread = false
    }

    /// Shows a scheduled task in the main area (the rail's Scheduled section): the thread stays loaded behind it.
    func selectTask(_ name: String) {
        tasks.selection = name
        tasks.newShown = false
        mode = .tasks
        newThread = false
    }

    /// Reads the list again, off the main actor, when something in it moved (or `force`).
    func refreshThreadList(force: Bool = false) async {
        guard let project else {
            (threads.listing, threads.signature) = (ThreadListing(), nil)
            return
        }
        let (mine, cache, pullRequests) = (generation, threadRowCache, threads.pullRequests)
        let moved = await Task.detached { ThreadListLoader.signature(project: project) }.value
        guard mine == generation, force || moved != threads.signature else { return }
        let listing = await Task.detached {
            ThreadListLoader.load(project: project, cache: cache, pullRequests: pullRequests)
        }.value
        guard mine == generation else { return }
        threads.signature = moved
        if listing != threads.listing { threads.listing = listing }
    }

    /// Moves the list to another project: its rows are read again, and what GitHub said of each project's pull requests stays with it.
    func forgetThreadList(switchingTo path: String?) {
        (threadRowCache, threads.signature) = (ThreadListLoader.Cache(), nil)
        threads.switchProject(to: path)
    }

    /// The poll's reads of GitHub, each on its own task: a slow `gh` must not hold up following the log.
    func readGitHubIfDue() {
        if pullRequestCIIsDue { Task { await refreshPullRequestCI() } }
        if pullRequestsAreDue { Task { await refreshPullRequests() } }
        if !threads.unwrittenOutcomes.isEmpty { Task { await retryOutcomeWrites() } }
        if !threads.readingOthers { Task { await readOtherProjectsPullRequests() } }
    }

    /// The listed threads whose shipped pull request GitHub has not been asked about for `pullRequestInterval`.
    private var pullRequestsDue: [String] {
        threads.listing.rows.compactMap { row in
            guard row.pullRequest != nil else { return nil }
            guard let readAt = threads.pullRequestsReadAt[row.id] else { return row.id }
            return readAt.duration(to: .now) >= ThreadListModel.pullRequestInterval ? row.id : nil
        }
    }

    var pullRequestsAreDue: Bool { !threads.readingPullRequests && !pullRequestsDue.isEmpty }

    /// Asks GitHub what became of the listed threads' pull requests, one at a time, and lists them again. A read that fails forgets
    /// what was known, so the row says what the log says: a merge is shown only once GitHub confirmed it.
    func refreshPullRequests(force: Bool = false) async {
        guard let project, !threads.readingPullRequests else { return }
        let due = force ? threads.listing.rows.filter { $0.pullRequest != nil }.map(\.id) : pullRequestsDue
        guard !due.isEmpty else { return }
        let mine = generation
        threads.readingPullRequests = true
        threads.syncing = due.contains { threads.pullRequestsReadAt[$0] == nil }
        // A read for a project that was closed meanwhile must not switch off what the project now open is showing.
        defer {
            threads.readingPullRequests = false
            if mine == generation { threads.syncing = false }
        }
        for id in due {
            let read = try? await actions.pullRequestStatus(project, id)
            guard mine == generation else { return }
            threads.pullRequests[id] = read
            threads.pullRequestsReadAt[id] = .now
            // A merge goes into the thread's log, so it is known from then on without asking GitHub.
            if let read, read.state != .open { await recordOutcome(read, thread: id, in: project, generation: mine) }
            // Each answer is shown as it comes, not after the last thread has been asked about.
            await refreshThreadList(force: true)
        }
    }

    /// Writes `pr.merged` or `pr.closed` to the thread's log (it only writes a file in the project, so the real writer runs in tests too). A write
    /// that failed is kept and tried again on the next poll, so a log another process held does not leave the merge unrecorded.
    /// `mine` is the project's generation when the merge was read: an answer for a project that is no longer open is dropped, never kept.
    func recordOutcome(_ status: PRStatus, thread: String, in project: Project, generation mine: Int) async {
        guard mine == generation, let git = try? GitRunner.discover() else { return }
        let result = await ThreadService(project: project, git: git).recordOutcome(id: thread, status: status)
        guard mine == generation else { return }
        if result == .failed { threads.unwrittenOutcomes[thread] = status } else { threads.unwrittenOutcomes[thread] = nil }
    }

    /// Tries again the merges whose write failed.
    func retryOutcomeWrites() async {
        guard let project else { return }
        let mine = generation
        for (thread, status) in threads.unwrittenOutcomes {
            await recordOutcome(status, thread: thread, in: project, generation: mine)
        }
        await refreshThreadList(force: true)
    }

    /// What the thread screen read of its own pull request is the row's too, so the rail and the banner agree.
    func notePullRequest(_ status: PRStatus?, thread: String) {
        guard threads.pullRequests[thread] != status else { return }
        threads.pullRequests[thread] = status
        threads.pullRequestsReadAt[thread] = .now
        let (project, mine) = (project, generation)
        Task {
            if let project, let status, status.state != .open {
                await recordOutcome(status, thread: thread, in: project, generation: mine)
            }
            await refreshThreadList(force: true)
        }
    }
}

extension ProjectStore {
    /// The thread the inbox must list because it is what the window shows: the thread screen's, only while a thread is what is chosen. A task
    /// page, the new-thread screen or a New task screen over a thread that was open leaves it to the ordinary rules.
    var railShown: String? {
        guard mode == .thread, !newThread, case .thread(let snapshot) = screen else { return nil }
        return snapshot.id
    }

    /// Whether the Done section of the project on screen lists every finished thread.
    var doneOpen: Bool { inboxDoneOpen.contains(project?.root.path ?? "") }

    /// Opens or closes the Done section of the project on screen.
    func toggleDoneOpen() {
        let key = project?.root.path ?? ""
        if inboxDoneOpen.contains(key) { inboxDoneOpen.remove(key) } else { inboxDoneOpen.insert(key) }
    }
}
