import AppKit
import Foundation
import Observation
import WorkbenchCore

/// What needs a person right now, across the open project's thread and tasks, and the one notification each new item gets.
///
/// The rule, in order: the first look at a project is its baseline (what is already there is shown in the count and never
/// announced: opening the app is not news); after that an item that was not there before, and not seen, is posted once under its
/// identity, unless notifications are paused; a relaunch, a wake or a second poll of the same state posts nothing.
@MainActor @Observable final class AttentionCenter {
    static let interval: TimeInterval = 30
    static let seenLimit = 200

    /// The items that need you: not seen, and in the order they are shown (the thread first).
    private(set) var items: [AttentionItem] = []
    /// The system would not let the app notify: said once in the popover.
    private(set) var notificationsDenied = false
    /// Whether the denial was already said, so it is said once.
    private(set) var deniedWasShown = false
    private(set) var posts = 0

    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private let notifier: Notifier
    @ObservationIgnored private var project: String?
    @ObservationIgnored private var baseline: Set<String> = []
    @ObservationIgnored private var announced: Set<String> = []
    /// The tasks as last read, kept when a read fails so the count does not drop to zero on a hiccup.
    @ObservationIgnored private var lastTasks: [TaskEntry] = []
    @ObservationIgnored private var lastThread: ThreadAttention?
    /// The project's tasks have been read once: until then the baseline is only what the thread said, and the first read of the
    /// tasks completes it (it is not news that yesterday's run failed).
    @ObservationIgnored private var tasksBaselined = false
    /// The thread's CI has been read once, for the same reason.
    @ObservationIgnored private var threadBaselined = true

    init(preferences: Preferences, notifier: Notifier = NullNotifier()) {
        self.preferences = preferences
        self.notifier = notifier
    }

    var paused: Bool {
        get { preferences.notificationsPaused }
        set { preferences.notificationsPaused = newValue }
    }

    @ObservationIgnored private var polling: Task<Void, Never>?
    @ObservationIgnored private var activation: NSObjectProtocol?

    /// Calls `look` now and then every `interval` for as long as the app runs, whatever screen or window is up.
    func startPolling(_ look: @escaping @MainActor () async -> Void) {
        guard polling == nil else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                await look()
                try? await Task.sleep(for: .seconds(Self.interval))
                if self == nil { return }
            }
        }
        // The app coming to the front is a look too: a task that broke in the background is shown at once.
        activation = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in await look() }
        }
    }

    func stopPolling() {
        polling?.cancel()
        polling = nil
        if let activation { NotificationCenter.default.removeObserver(activation) }
        activation = nil
    }

    func sayDeniedOnce() { deniedWasShown = true }

    /// Takes one look: the project path, the thread on screen, and the tasks (nil when they could not be read: the last good ones stay).
    func observe(project path: String?, projectName: String, thread: ThreadAttention?, tasks: [TaskEntry]?) async {
        guard let path else {
            (project, baseline, announced, items, lastTasks, lastThread) = (nil, [], [], [], [], nil)
            tasksBaselined = false
            return
        }
        let first = path != project
        if first { (project, baseline, announced, lastTasks, tasksBaselined, threadBaselined) = (path, [], [], [], false, false) }
        if let tasks { lastTasks = tasks }
        lastThread = thread
        let seen = Set(preferences.seenAttention)
        let all = AttentionItems.derive(thread: thread, tasks: lastTasks).filter { !seen.contains(seenKey($0.id)) }
        items = all
        // The first look at a project, and the first look that has its tasks, are baselines: what is there is counted, not announced.
        let ciReady = thread?.ciLoaded ?? true
        if first || (!tasksBaselined && tasks != nil) || (!threadBaselined && ciReady) {
            if tasks != nil { tasksBaselined = true }
            if ciReady { threadBaselined = true }
            baseline.formUnion(all.map(\.id))
            return
        }
        // Until the thread's CI has been read, nothing from the thread is announced: its failure may be an old one.
        guard threadBaselined else { return }
        for item in all where !baseline.contains(item.id) && !announced.contains(item.id) {
            announced.insert(item.id)
            guard !paused else { continue }
            let notice = Notice(id: item.id, title: projectName, body: Self.body(item), route: item.route, project: path)
            posts += 1
            if await notifier.post(notice) == .denied { notificationsDenied = true }
        }
    }

    /// "Review · turn 2 done" or "bump-contract-details failed: the check failed…".
    static func body(_ item: AttentionItem) -> String {
        switch item.route {
        case .thread: "\(item.title): \(item.reason)"
        case .task: "\(item.title) \(item.reason)"
        }
    }

    /// The person looked at this task: its current items stop counting. A newer failure is a new identity and counts again.
    func markSeen(task name: String) {
        let ids = items.filter { $0.route == .task(name) }.map(\.id)
        guard !ids.isEmpty else { return }
        markSeen(ids)
    }

    /// A mark belongs to its project: two projects with a task of the same name and the same run are not the same reason.
    private func seenKey(_ id: String) -> String { "\(project ?? "")|\(id)" }

    func markSeen(_ ids: [String]) {
        var seen = preferences.seenAttention
        for id in ids.map(seenKey) where !seen.contains(id) { seen.append(id) }
        preferences.seenAttention = Array(seen.suffix(Self.seenLimit))
        items.removeAll { ids.contains($0.id) }
    }
}
