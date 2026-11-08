import AppKit
import Foundation
import Observation
import WorkbenchCore

/// What the Doctor chip says. Doctor runs the project's own setup and check in a throwaway worktree, so it costs what
/// the project says and runs only when asked.
enum DoctorChip: Equatable {
    case notRun
    case running
    case healthy(seconds: Double)
    case problem(String)
}

/// A project the app has opened, as the project menu lists it.
struct RecentProject: Equatable, Identifiable {
    var path: String
    var name: String
    var isCurrent: Bool
    /// This app has a run going in it: switching away does not stop it.
    var isRunning: Bool
    /// Why it cannot be opened now (the folder is gone, it is no longer a git repository); nil when it can.
    var unavailable: String?
    var id: String { path }
}

/// The one store of a window: the project, the screen derived from its newest thread's log, and the Doctor chip. It holds
/// no thread state outside the log and the chosen repo path, and it reads the log off the main actor, only when `stat`
/// says it changed.
@MainActor @Observable final class ProjectStore {  // swiftlint:disable:this type_body_length
    /// Set by the store and its extensions only (`applyPullRequestCI` adds what GitHub said to the thread on screen).
    var screen: ProjectScreen
    private(set) var project: Project? { didSet { rebindSession() } }
    /// The thread screens or the tasks: the rail's switch. The tasks are the project's, so the thread on screen is not changed by it.
    var mode: WindowMode = .thread
    /// The Tasks screen's data, read from the core while that screen is shown.
    let tasks = TasksModel()
    /// How many of a project's threads the rail lists, by project: `Show more` adds a page. Kept for the session, not on disk.
    /// The projects whose Done section is open in the inbox (by path); closed unless the person opened it.
    var inboxDoneOpen: Set<String> = []
    /// The rail lists the inbox of every project (the top tile), not the open project's own; and whether its Done section is open.
    var allProjects = false
    var railFocused = false  // the rail has the keys: a screen opening under it must not take the caret
    var allInboxDoneOpen = false
    /// What needs a person (a thread to review, a task that broke), the count and the notification each new one gets.
    let attention: AttentionCenter
    private(set) var doctor: DoctorChip = .notRun
    /// What the app is doing for the person right now, in words ("Discarding: removing the worktree and branch…"); nil when it is
    /// waiting for them, or when what it is doing belongs to another project or thread than the one on screen. Every action that
    /// takes a moment sets it, so a click is never followed by a window that looks asleep.
    var busy: String? { current.busyText }
    /// The session of the thread on screen: what the window holds for it (goal, review, errors) lives here, not in the store.
    fileprivate(set) var current: ThreadSession
    /// The other sessions that have work going on or something still to show, and this one's if it has any; a session leaves when it has neither.
    fileprivate(set) var sessions: [ThreadSession.Key: ThreadSession] = [:]
    /// Opens an address in the browser; a test replaces it so none opens.
    /// How long an action waits for goal edits already made before it says they did not finish; tests make it short.
    @ObservationIgnored var goalEditWait: Duration = .seconds(10)
    @ObservationIgnored var openExternal: (URL) -> Void = { _ = NSWorkspace.shared.open($0) }
    /// Callers of `untilIdle`, resumed once no action is working and no decision is being recorded.
    @ObservationIgnored private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    /// Returns once no other action holds the window (an "Open in Herdr" still going, a decision being recorded), so work the
    /// app does on its own is not refused for a click that was already in progress.
    func untilIdle() async {
        while anyBusy || deciding {
            await withCheckedContinuation { idleWaiters.append($0) }
        }
    }

    private func resumeIdleWaiters() {
        guard !anyBusy, !deciding, !idleWaiters.isEmpty else { return }
        let waiting = idleWaiters
        idleWaiters = []
        waiting.forEach { $0.resume() }
    }
    /// The goal agent is drafting a goal from a request.
    /// The new-thread screen is up: the main area asks what to work on, and nothing is on screen as a thread.
    var newThread = false
    /// What is typed on it: kept while another row is looked at, cleared when a thread is made.
    var newThreadText = ""
    /// Whether the project card under the project pill is up.
    var pickingProject = false
    /// The project whose Agents card is up, by path: any project of the rail, not only the open one (`showAgents(for:)`).
    var agentsProject: String?
    /// The modals over the feed that no other state decides (`AppModals.swift`).
    var modals = ModalState()
    /// The open project's agent roles as its config sets them: read when the card or a screen that names the agent appears.
    var agentConfig = AgentConfigState.unread
    /// The roles of `agentsProject` as its config sets them, for the card: that project's, which may not be the open one.
    var cardAgentConfig = AgentConfigState.unread
    /// What is written in each thread's guidance field. It lives here, not in the view, so a send that the run refuses to start does not
    /// lose it and another thread does not see it; it is cleared when a turn has begun and when the project changes.
    var guidanceNotes: [String: String] = [:]
    /// Bumped to focus the guidance field: the menu bar's `Send back…` asks for it.
    var guidanceFocus = 0
    /// The last request the field has acted on: a field that appears after the request (the window was on Tasks) still takes it.
    var guidanceFocusServed = 0
    /// The denied calls the Review card offers to decide; read when it opens.
    var sendBackGrants: [GrantRow] = []
    /// Whether a `herdr` was found for the open project: "Open in Herdr" is shown only then.
    var herdrFound = false
    /// What the last "Run in Herdr" did; `herdrHandoffOutcome` shows it for its own thread.
    var herdrHandoff: HerdrHandoffShown?
    /// Decisions being recorded. One at a time, and a send waits for them: a grant refused for a live run is lost.
    var grantsInFlight = 0
    var drafting = false
    /// The last draft was refused because the config names no goal agent: the sheet offers to name one.
    var goalAgentOff = false
    @ObservationIgnored var draftStop: DraftStop?
    /// A pull request review round on screen: the one that just ran, or the latest one the person asked to see.
    var prReviewShown: PRReviewShown?
    /// Why a fix round from the findings sheet was refused (the sheet covers the window's own error line).
    var followUpError: String?
    /// Bumped when the sheet closes: a fix round still being read for it starts nothing.
    @ObservationIgnored var followUpRequest = 0
    /// A fix round started from the findings sheet: when its run ends well it is accepted, shipped and reviewed without asking.
    @ObservationIgnored var fixRoundToShip: FixRound?
    /// The shipped pull request's CI as last read, and how often it is read again; the snapshot shows it only for its scope.
    @ObservationIgnored var prCI: PullRequestCIState
    var deciding = false { didSet { resumeIdleWaiters() } }
    @ObservationIgnored let preferences: Preferences
    /// The Run settings inspector is shown beside the feed (or over it, in a narrow window). Set by `setRunSettings`.
    var runSettingsOn: Bool
    /// A person has chosen (open or closed): only then may a narrow window open the inspector over the feed.
    var runSettingsChosen: Bool
    /// The feed's centre is wide enough to hold the inspector beside it (set by the feed from its layout).
    var runSettingsFits = false
    /// The project paths the menu lists, most recent first; the app's own preference, never a file in a project.
    var recentPaths: [String] = []
    /// The projects on the rail, in order (`ProjectStore+Rail.swift`).
    var railPaths: [String] = []
    /// What the other tiles count, read on the attention poll (`ProjectStore+Summaries.swift`).
    let railSummaries = RailSummaries()
    /// Projects git refused when one was chosen, with why: shown unavailable so they can be removed.
    var refusedPaths: [String: String] = [:]
    /// What the last refusal to open a project said, so the next try clears that and not what the thread said otherwise.
    @ObservationIgnored var lastRefusal: String?
    @ObservationIgnored var currentThread: String? { didSet { rebindSession() } }
    /// The thread the person picked in the list; nil follows the active thread, else the newest. Cleared by a project change and by a new goal.
    @ObservationIgnored var selectedThread: String?
    /// The project's threads as the list shows them, kept current by the store.
    let threads = ThreadListModel()
    @ObservationIgnored var threadRowCache = ThreadListLoader.Cache()
    @ObservationIgnored var lastWatch: ProjectLoader.Watch?
    @ObservationIgnored private var polling: Task<Void, Never>?
    @ObservationIgnored private let intervals: (working: Duration, idle: Duration)
    /// Bumped each time another project is opened: an answer for an earlier one (a reload or a doctor run that was still
    /// in flight) is dropped, never shown under the new project.
    @ObservationIgnored var generation = 0
    /// Seams for tests that need to hold a read or a doctor run half way; the app uses the real ones.
    @ObservationIgnored private let loader: @Sendable (Project, String?) -> ProjectLoader.Loaded
    @ObservationIgnored private let doctorRunner: @Sendable (Project, String?) async -> DoctorChip
    @ObservationIgnored private let goalLoader: @Sendable (Project, String) async -> GoalModel
    @ObservationIgnored let actions: GoalActions
    /// Asks for a folder (the file panel in the app); nil when the person cancels.
    @ObservationIgnored let folderChooser: @MainActor () -> URL?

    /// `screen` is for previews and tests that show a fixed state without a project on disk.
    init(
        preferences: Preferences, screen: ProjectScreen = .noProject, project: Project? = nil,
        intervals: (working: Duration, idle: Duration) = (.milliseconds(250), .seconds(2)),
        ciIntervals: (pending: Duration, settled: Duration) = (.seconds(10), .seconds(60)),
        loader: @escaping @Sendable (Project, String?) -> ProjectLoader.Loaded = {
            ProjectLoader.load(project: $0, selected: $1)
        },
        doctorRunner: @escaping @Sendable (Project, String?) async -> DoctorChip = {
            await ProjectStore.runCoreDoctor($0, base: $1)
        },
        goalLoader: @escaping @Sendable (Project, String) async -> GoalModel = {
            await GoalModel.load(project: $0, thread: $1, verifierSkill: GoalModel.coreVerifierSkill(project: $0))
        },
        actions: GoalActions = .core,
        folderChooser: @escaping @MainActor () -> URL? = ProjectPickerCard.folderPanel,
        notifier: Notifier = NullNotifier()
    ) {
        self.attention = AttentionCenter(preferences: preferences, notifier: notifier)
        self.folderChooser = folderChooser
        self.goalLoader = goalLoader
        self.actions = actions
        self.preferences = preferences
        let recents = Self.merged(preferences.recentProjects, preferences.projectPath)
        (self.recentPaths, self.railPaths) = (recents, preferences.railProjects ?? RailProjects.seed(fromRecents: recents))
        self.screen = screen
        self.project = project
        self.current = ThreadSession(key: ThreadSession.Key(project: project, thread: nil))
        self.intervals = intervals
        self.prCI = PullRequestCIState(intervals: ciIntervals)
        self.loader = loader
        self.runSettingsOn = preferences.runSettings
        self.runSettingsChosen = preferences.runSettingsChosen
        self.doctorRunner = doctorRunner
        current.onSaid = { [weak self] in self?.adopt($0) }
    }

    /// The raw log of what the window shows, for the footer's button: a thread's, or the damaged one's.
    var logURL: URL? {
        switch screen {
        case .thread(let snapshot): snapshot.logURL
        case .logCorrupt(let thread, _): project?.eventsURL(thread)
        default: nil
        }
    }

    // MARK: Choosing the project

    /// Opens what the preferences remember, if it is still a git repository. A path that went away is "no project", not
    /// an error the person has to dismiss.
    func restore() async {
        guard let path = preferences.projectPath else { return }
        guard FileManager.default.fileExists(atPath: path) else {
            preferences.projectPath = nil
            return
        }
        _ = await open(URL(fileURLWithPath: path))
    }

    /// Validates `url` as inside a git repository and, only then, remembers its main checkout and shows it.
    @discardableResult
    func open(_ url: URL) async -> Bool {
        let located: Project
        do {
            located = try await Project.locate(from: url, git: try GitRunner.discover())
        } catch {
            // The project that was open is closed: showing this error over it would let its next poll erase the error, and leave
            // Doctor enabled for a project the window no longer names. What is remembered stays, so a relaunch restores it.
            generation += 1
            (pickingProject, newThread, showingAgents, agentConfig, modals) = (false, false, false, .unread, ModalState())
            newThreadText = ""
            clearGuidance()
            (project, currentThread, lastWatch, doctor, selectedThread) = (nil, nil, nil, .notRun, nil)
            (current.goal, current.review, current.pendingDiscard) = (nil, nil, nil)
            threads.switchProject(to: nil)
            screen = .notAGitRepository(path: url.path)
            return false
        }
        // Leaving a project: its tile keeps what the window last read of it, not what the poll read before.
        if located.root != project?.root { captureLiveCounts() }
        preferences.projectPath = located.root.path
        remember(located.root.path)
        generation += 1
        // A goal being written belongs to the project it was started in: another project does not inherit it.
        (pickingProject, newThread, showingAgents, agentConfig, modals) = (false, false, false, .unread, ModalState())
        // What was typed was for the project it was typed in: never offered to another.
        newThreadText = ""
        clearGuidance()
        current.pendingDiscard = nil
        prReviewShown = nil
        // The thread goes first: the project alone would pair the new project with the old project's thread id.
        (currentThread, lastWatch, selectedThread) = (nil, nil, nil)
        // A thread id means another thread in another project: what was read for the old project is not the new one's.
        forgetThreadList(switchingTo: located.root.path)
        project = located
        herdrFound = actions.herdrFound(located)
        doctor = .notRun
        (current.goal, current.review) = (nil, nil)
        screen = .opening(path: located.root.path)
        await reload()
        return true
    }

    // MARK: Following the log

    /// Looks once: reads nothing when nothing moved since the last look.
    func refresh() async {
        guard let project else { return }
        let (thread, mine) = (currentThread, generation)
        let now = await Task.detached { ProjectLoader.watch(project: project, thread: thread) }.value
        if mine == generation && now != lastWatch { await reload() } else { await refreshThreadList() }
    }

    func reload() async {
        guard let project else { return }
        let (mine, loader, selected) = (generation, self.loader, selectedThread)
        let result = await Task.detached { loader(project, selected) }.value
        guard mine == generation else { return }
        var model: GoalModel?
        if let thread = result.thread, case .thread = result.screen {
            let goalLoader = self.goalLoader
            model = await Task.detached { await goalLoader(project, thread) }.value
            guard mine == generation else { return }
        }
        var reviewed: ReviewModel?
        if let thread = result.thread, case .thread(let shown) = result.screen, shown.state.review.status == .awaitingReview {
            let load = actions.loadReview
            reviewed = await Task.detached { await load(project, thread) }.value.map(ReviewModel.derive)
            guard mine == generation else { return }
        }
        // Likewise a read that began before another thread was picked: the read `select` started is the one that counts.
        guard selected == selectedThread else { return }
        (screen, currentThread, lastWatch) = (result.screen, result.thread, result.watch)
        (current.goal, current.review) = (model, reviewed)
        applyOwnership()
        applyPullRequestCI()
        await refreshThreadList()
        await observeAttention(readTasks: false)
        if case .thread(let shown) = screen, case .ended? = shown.run?.phase { current.stopping = false }
        // Only the thread the run was started in can say it has begun: another project's log is not this run's.
        let session = current
        if let after = session.awaitingAfterTurn, case .thread(let shown) = screen {
            if shown.state.lastTurn > after {
                guidanceNotes[shown.id] = nil
                endRunStart(session)
            }
        }
    }

    /// The window is no longer waiting for a run to show up.
    private func endRunStart(_ session: ThreadSession) {
        guard session.awaitingRun else { return }
        session.awaitingAfterTurn = nil
        setBusy(nil, in: session)
    }

    /// Runs `body` with `text` shown as what the app is doing, and clears it after, whatever happened.
    /// One at a time: a second click while the first is still working is ignored, so the first one's end cannot take the line
    /// down while the second is still going.
    func working(_ text: String, _ body: () async -> Void) async {
        guard let project else { return }
        let doing = busy ?? sessions.values.lazy.compactMap(\.busyText).first
        if let doing { return actionError = "Still busy: \(doing)" }
        let mine = session(project, currentThread)
        setBusy(text, in: mine)
        defer { if !mine.awaitingRun { setBusy(nil, in: mine) } }
        await body()
    }

    /// Says what a `working` body moved on to, such as from reading a plan to doing it; nothing when no work is going on.
    func nowWorking(_ text: String) {
        sessions.values.first { $0.busyText != nil }?.busyText = text
    }

    // MARK: Goal actions

    /// Approves the goal, and only when that worked starts the run: a failed approve starts nothing. The run is core's, started
    /// here and left to the log to report.
    func approveAndRun() async {
        guard let project, let thread = currentThread else { return }
        if starting || current.ownedRun != nil {
            actionError = starting ? "The goal is already being approved." : "A run is already going in this thread."
            return
        }
        let mine = generation
        let mineSession = session(project, thread)
        mineSession.starting = true
        setBusy("Saving your edits to the goal…", in: mineSession)
        actionError = nil
        defer {
            mineSession.starting = false
            if !mineSession.awaitingRun { setBusy(nil, in: mineSession) }
        }
        // Changes already made to the goal are written first, so what is approved is what the window shows.
        guard await goalEditsSettled(in: mineSession) else { return }
        setBusy("Approving the goal…", in: mineSession)
        do {
            try await actions.approve(project, thread)
        } catch {
            if mine == generation { mineSession.actionError = "\(error)" }
            await reload()
            return
        }
        await reload()
        // The window may have moved to another project while approval ran: the approval stands in the log, the run is not started.
        guard mine == generation else { return }
        startRun(project, thread, generation: mine)
    }

    /// Starts the turn and keeps hold of it, so Stop reaches it. Refused while a run of this app is still going.
    func startRun(
        _ project: Project, _ thread: String, generation mine: Int, options: RunOptions = RunOptions()
    ) {
        // Said on the thread the run is for: an approval that took a moment may have left another one on screen.
        let started = session(project, thread)
        guard started.ownedRun == nil else {
            started.actionError = "A run is already going in this thread."
            return
        }
        let handle: RunHandle
        do { handle = try actions.makeRun(project, thread, options) } catch {
            started.actionError = "The run did not start: \(error)"
            return
        }
        // The turn is not in the log until the worktree is cut and setup has run: say so until it is.
        var turnNow = 0
        if case .thread(let shown) = screen, shown.id == thread { turnNow = shown.state.lastTurn }
        started.awaitingAfterTurn = turnNow
        started.ownedRun = ThreadSession.OwnedRun(handle: handle, project: project, thread: thread)
        setBusy("Starting the run…", in: started)
        applyOwnership()
        Task { [weak self] in
            var failed = false
            do {
                try await handle.run()
                // A turn quick enough to end between two polls is never seen to begin: its note is spent all the same.
                // Only in the project the run was started in: another project's thread of the same id has its own text.
                if self?.generation == mine { self?.guidanceNotes[thread] = nil }
            } catch {
                failed = true
                self?.runFailed(error, in: started, generation: mine)
            }
            await self?.runEnded(started, failed: failed)
        }
    }

    /// The runner the app holds writes the log a moment after it starts: an open turn with no live runner is not a dead one.
    private func applyOwnership() {
        guard runningHere, case .thread(var shown) = screen, shown.run?.phase == .orphaned else { return }
        shown.run?.phase = .working
        screen = .thread(shown)
    }

    private func runEnded(_ session: ThreadSession, failed: Bool) async {
        session.ownedRun = nil
        session.stopping = false
        endRunStart(session)
        settled()
        await reload()
        // A run that returns leaves its turn ended in the log; one that does not has died without saying how.
        let orphaned = if case .thread(let shown) = screen { shown.run?.phase == .orphaned } else { false }
        if orphaned, actionError == nil {
            actionError = "The run ended without recording how the turn ended. Run again records it as interrupted."
        }
        // The run's own outcome, not `actionError`: another action (an "Open in Herdr" still going) may set that meanwhile.
        await continueFixRound(runFailed: failed || orphaned)
    }

    /// The next turn after one that did not finish. A turn that succeeded goes to Review and `send-back`, which is not this.
    func runAgain() async {
        guard let project, let thread = currentThread, !starting else { return }
        actionError = nil
        startRun(project, thread, generation: generation)
    }

    /// One file's patch as core bounds it.
    func patchText(_ path: String) async -> String {
        guard let project, let thread = currentThread else { return "" }
        do {
            guard let patch = try await actions.patch(project, thread, path) else { return "No patch for \(path)." }
            return ReviewReport.render(patch)
        } catch { return "\(error)" }
    }

    /// Whether this window's thread is the one the app is running.
    var runningHere: Bool { ownedRuns.contains { $0.project == project && $0.thread == currentThread } }

    /// Asks the turn to end: through the runner this app holds, else the process a terminal's `workbench run` holds. The turn
    /// still ends with a recorded `stopped`; this only asks.
    func stopTurn() async {
        guard let project, let thread = currentThread, !stopping else { return }
        let mine = current
        mine.stopping = true
        actionError = nil
        if let owned = sessions[ThreadSession.Key(project: project, thread: thread)]?.ownedRun {
            await owned.handle.stop()
        } else if await !actions.requestStop(project, thread) {
            mine.stopping = false
            mine.actionError = "Nothing is running this thread."
        }
    }

    func openWorktree() async {
        guard let project, let thread = currentThread else { return }
        actionError = nil
        await working("Opening the worktree…") {
            do { try await actions.openWorktree(project, thread) } catch { actionError = "\(error)" }
        }
    }

    /// A run that could not start (no provider executable, a config that does not load) records no turn, so this is the only
    /// place the person hears of it. An answer for another project is dropped.
    private func runFailed(_ error: Error, in session: ThreadSession, generation mine: Int) {
        guard mine == generation else { return }
        endRunStart(session)
        // On the thread it was started for: the window may be showing another by now.
        session.actionError = "The run did not start: \(error)"
    }

    /// Polls every 250 ms while the thread is working and every 2 s otherwise, until `stopPolling`.
    func startPolling() {
        guard polling == nil else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                self.readGitHubIfDue()
                let working = self.isWorking
                try? await Task.sleep(for: working ? self.intervals.working : self.intervals.idle)
            }
        }
    }

    func stopPolling() {
        polling?.cancel()
        polling = nil
    }

    private var isWorking: Bool {
        if busy != nil || !ownedRuns.isEmpty { return true }
        if case .thread(let snapshot) = screen { return snapshot.attention == .working }
        return false
    }
}

// MARK: Doctor

extension ProjectStore {
    /// Runs doctor on the thread's base (else the project's default one) and reports what it found. Off the main actor:
    /// the work is core's, awaited here. An answer for a project that is no longer the open one is dropped.
    func runDoctor() async {
        guard let project, doctor != .running else { return }
        doctor = .running
        let (mine, runner) = (generation, doctorRunner)
        var base: String?
        if case .thread(let snapshot) = screen { base = snapshot.base }
        let chip = await runner(project, base)
        guard mine == generation else { return }
        doctor = chip
    }

    /// Core's doctor, timed, with its verdict as the chip says it.
    nonisolated static func runCoreDoctor(_ project: Project, base known: String?) async -> DoctorChip {
        let clock = ContinuousClock()
        let started = clock.now
        do {
            let git = try GitRunner.discover()
            let base: String
            if let known { base = known } else { base = await ThreadService(project: project, git: git).defaultBase() }
            let report = try await Doctor(project: project, git: git).run(base: base)
            let elapsed = started.duration(to: clock.now)
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            switch report.verdict {
            case .passed: return .healthy(seconds: seconds)
            case .stepsFailed: return .problem("The declared setup or check failed")
            case .stopped: return .problem("Doctor was stopped")
            case .cleanupFailed(let problem): return .problem(problem)
            }
        } catch {
            return .problem("\(error)")
        }
    }
}

private extension ProjectStore {
    /// Follows the window to another project or thread: its session is the one that has work going on for it, else a fresh one.
    func rebindSession() {
        let key = ThreadSession.Key(project: project, thread: currentThread)
        guard key != current.key else { return }
        if !current.isSpent { sessions[current.key] = current }
        current = sessions[key] ?? newSession(key)
        settled()
    }
    /// The thread's session: the one on screen, the one with work going on for it, or a new one.
    func session(_ project: Project, _ thread: String?) -> ThreadSession {
        let key = ThreadSession.Key(project: project, thread: thread)
        if key == current.key { return current }
        return sessions[key] ?? newSession(key)
    }
    func newSession(_ key: ThreadSession.Key) -> ThreadSession {
        let made = ThreadSession(key: key)
        made.onSaid = { [weak self] in self?.adopt($0) }
        return made
    }
    /// A session that has something to show is kept while the window is elsewhere.
    func adopt(_ session: ThreadSession) {
        let home = session.key == current.key ? current : sessions[session.key]
        if let home, home !== session {
            home.absorb(session)
        } else if session !== current {
            sessions[session.key] = session
        }
    }
    /// Whether any session is working: one action at a time holds the window.
    var anyBusy: Bool { sessions.values.contains { $0.busyText != nil } }
    var ownedRun: ThreadSession.OwnedRun? { ownedRuns.first }

    func setBusy(_ text: String?, in session: ThreadSession) {
        session.busyText = text
        sessions[session.key] = session
        settled()
    }

    /// Drops the sessions with nothing going on and wakes whoever waits for the window to be free.
    func settled() {
        if sessions.values.contains(where: \.isSpent) { sessions = sessions.filter { !$0.value.isSpent } }
        resumeIdleWaiters()
    }
}

extension ProjectStore {
    /// The session of a thread (or of a chat with no thread yet), the one on screen or the one the store keeps for it.
    func threadSession(_ project: Project, _ thread: String?) -> ThreadSession { session(project, thread) }

    /// Marks a chat turn as going (or over) in `session`, which the store keeps while it replies, wherever the window is.
    func setReplying(_ on: Bool, in session: ThreadSession, stop: DraftStop? = nil) {
        session.replying = on
        session.chatStop = on ? stop : nil
        sessions[session.key] = session
        settled()
    }
}
