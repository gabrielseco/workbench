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
@MainActor @Observable final class ProjectStore {
    private(set) var screen: ProjectScreen
    private(set) var project: Project?
    private(set) var doctor: DoctorChip = .notRun
    /// The goal of the thread on screen, read with the config; nil without a thread.
    private(set) var goal: GoalModel?
    /// What the last Approve, Run or New goal said when it did not go through.
    /// What the last action said when it did not go through. Set by the store's own extensions too.
    var actionError: String?
    /// Why the last change to the draft goal was refused (shown under its blocks); nil after one that went through.
    var goalEditError: String?
    /// Counts the edits that have ended, so a field whose edit was refused can show what the file has.
    var goalEditSerial = 0
    @ObservationIgnored var goalEdits: Task<Void, Never>?
    /// Something an action did not do that is not a failure, such as files left out of a diff.
    var actionNote: String?
    private(set) var starting = false
    /// What the app is doing for the person right now, in words ("Discarding: removing the worktree and branch…"); nil when it is
    /// waiting for them, or when what it is doing belongs to another project or thread than the one on screen. Every action that
    /// takes a moment sets it, so a click is never followed by a window that looks asleep.
    var busy: String? { busyText.flatMap { busyScope == currentScope ? $0 : nil } }
    private var busyText: String?
    /// The project and thread the busy text is about: `busy` shows only while they are the ones on screen.
    private var busyScope: String?
    /// The project and thread on screen, as one value to compare.
    private var currentScope: String? { project.map { "\($0.root.path)|\(currentThread ?? "")" } }
    /// A run was started and the log does not show a newer turn than this one yet (the worktree is being cut, setup is installing),
    /// in the thread that scope names: the text stays up until it does, or the run ends or fails.
    @ObservationIgnored private var awaitingAfterTurn: Int?
    @ObservationIgnored private var awaitingScope: String?
    private var awaitingRun: Bool { awaitingAfterTurn != nil }

    private func setBusy(_ text: String?) { (busyText, busyScope) = (text, text == nil ? nil : currentScope) }
    /// The goal agent is drafting a goal from a request.
    /// Whether the New goal popover is up; every "New goal…" button sets it and `RootView` shows the popover over the window.
    var namingGoal = false
    /// Whether the Send back card is up; the Review screen's button sets it, `sendBack` clears it once a turn has started.
    var sendingBack = false
    /// What is written in the Send back card. It lives here, not in the card, so a send that the run refuses to start does not
    /// lose it; it is cleared when a turn has begun, on Cancel and when the project changes.
    var sendBackNote = ""
    /// The denied calls the card offers to decide; read when it opens.
    var sendBackGrants: [GrantRow] = []
    /// Decisions being recorded. One at a time, and a send waits for them: a grant refused for a live run is lost.
    var grantsInFlight = 0
    var drafting = false
    /// The last draft was refused because the config names no goal agent: the sheet offers to name one.
    var goalAgentOff = false
    @ObservationIgnored var draftStop: DraftStop?
    /// A turn the user is stopping: set from Stop until the log says it ended.
    private(set) var stopping = false
    /// The latest turn's review while it awaits one; nil otherwise.
    var review: ReviewModel?
    /// What core says Accept or Discard would do, shown for confirmation and passed back as `shown:` exactly as shown.
    var pendingAccept: AcceptPlan?
    var pendingDiscard: DiscardPlan?
    /// What Ship would push and open, shown for confirmation and passed back as shown.
    var pendingShip: ShipPreview?
    /// A pull request review round on screen: the one that just ran, or the latest one the person asked to see.
    var prReviewShown: PRReviewShown?
    /// The confirm in the findings sheet for a fix round, and why a start was refused (the sheet covers the window's own error line).
    var pendingFollowUp: FollowUpPlan?
    var followUpError: String?
    var deciding = false
    /// What the last decision did, in words: `Accepted: abc1234 on workbench/x`. Cleared by the next action.
    var notice: String?
    /// The run this app started and has not seen end. At most one: a second start is refused.
    @ObservationIgnored private var ownedRun: OwnedRun?

    private struct OwnedRun {
        var handle: RunHandle
        var project: Project
        var thread: String
    }

    @ObservationIgnored let preferences: Preferences
    /// The project paths the menu lists, most recent first; the app's own preference, never a file in a project.
    var recentPaths: [String] = []
    /// Projects git refused when one was chosen, with why: shown unavailable so they can be removed.
    var refusedPaths: [String: String] = [:]
    @ObservationIgnored var currentThread: String?
    @ObservationIgnored var lastWatch: ProjectLoader.Watch?
    @ObservationIgnored private var polling: Task<Void, Never>?
    @ObservationIgnored private let intervals: (working: Duration, idle: Duration)
    /// Bumped each time another project is opened: an answer for an earlier one (a reload or a doctor run that was still
    /// in flight) is dropped, never shown under the new project.
    @ObservationIgnored var generation = 0
    /// Seams for tests that need to hold a read or a doctor run half way; the app uses the real ones.
    @ObservationIgnored private let loader: @Sendable (Project) -> ProjectLoader.Loaded
    @ObservationIgnored private let doctorRunner: @Sendable (Project, String?) async -> DoctorChip
    @ObservationIgnored private let goalLoader: @Sendable (Project, String) async -> GoalModel
    @ObservationIgnored let actions: GoalActions

    /// `screen` is for previews and tests that show a fixed state without a project on disk.
    init(
        preferences: Preferences, screen: ProjectScreen = .noProject, project: Project? = nil,
        intervals: (working: Duration, idle: Duration) = (.milliseconds(250), .seconds(2)),
        loader: @escaping @Sendable (Project) -> ProjectLoader.Loaded = { ProjectLoader.load(project: $0) },
        doctorRunner: @escaping @Sendable (Project, String?) async -> DoctorChip = {
            await ProjectStore.runCoreDoctor($0, base: $1)
        },
        goalLoader: @escaping @Sendable (Project, String) async -> GoalModel = {
            await GoalModel.load(project: $0, thread: $1, verifierSkill: GoalModel.coreVerifierSkill(project: $0))
        },
        actions: GoalActions = .core
    ) {
        self.goalLoader = goalLoader
        self.actions = actions
        self.preferences = preferences
        self.recentPaths = Self.merged(preferences.recentProjects, preferences.projectPath)
        self.screen = screen
        self.project = project
        self.intervals = intervals
        self.loader = loader
        self.doctorRunner = doctorRunner
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
            namingGoal = false
            cancelSendBack()
            (project, currentThread, lastWatch, doctor, goal) = (nil, nil, nil, .notRun, nil)
            (review, pendingAccept, pendingDiscard, pendingShip) = (nil, nil, nil, nil)
            screen = .notAGitRepository(path: url.path)
            return false
        }
        preferences.projectPath = located.root.path
        remember(located.root.path)
        generation += 1
        // A goal being written belongs to the project it was started in: another project does not inherit it.
        namingGoal = false
        cancelSendBack()
        (pendingAccept, pendingDiscard, pendingShip, notice) = (nil, nil, nil, nil)
        prReviewShown = nil
        project = located
        doctor = .notRun
        (goal, review, goalEditError) = (nil, nil, nil)
        screen = .opening(path: located.root.path)
        (currentThread, lastWatch) = (nil, nil)
        await reload()
        return true
    }

    // MARK: Following the log

    /// Looks once: reads nothing when nothing moved since the last look.
    func refresh() async {
        guard let project else { return }
        let (thread, mine) = (currentThread, generation)
        let now = await Task.detached { ProjectLoader.watch(project: project, thread: thread) }.value
        if mine == generation && now != lastWatch { await reload() }
    }

    func reload() async {
        guard let project else { return }
        let (mine, loader) = (generation, self.loader)
        let result = await Task.detached { loader(project) }.value
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
        (screen, currentThread, lastWatch, goal, review) = (result.screen, result.thread, result.watch, model, reviewed)
        applyOwnership()
        if case .thread(let shown) = screen, case .ended? = shown.run?.phase { stopping = false }
        // Only the thread the run was started in can say it has begun: another project's log is not this run's.
        if let after = awaitingAfterTurn, awaitingScope == currentScope, case .thread(let shown) = screen {
            if shown.state.lastTurn > after {
                sendBackNote = ""
                endRunStart()
            }
        }
    }

    /// The window is no longer waiting for a run to show up.
    private func endRunStart() {
        guard awaitingRun else { return }
        (awaitingAfterTurn, awaitingScope) = (nil, nil)
        setBusy(nil)
    }

    /// Runs `body` with `text` shown as what the app is doing, and clears it after, whatever happened.
    /// One at a time: a second click while the first is still working is ignored, so the first one's end cannot take the line
    /// down while the second is still going.
    func working(_ text: String, _ body: () async -> Void) async {
        guard busyText == nil else { return }
        setBusy(text)
        defer { if !awaitingRun { setBusy(nil) } }
        await body()
    }

    // MARK: Goal actions

    /// Approves the goal, and only when that worked starts the run: a failed approve starts nothing. The run is core's, started
    /// here and left to the log to report.
    func approveAndRun() async {
        guard let project, let thread = currentThread, !starting else { return }
        if ownedRun != nil {
            actionError = "A run is already going."
            return
        }
        // Changes already made to the goal are written first, so what is approved is what the window shows.
        await goalEdits?.value
        let mine = generation
        starting = true
        setBusy("Approving the goal…")
        actionError = nil
        defer {
            starting = false
            if !awaitingRun { setBusy(nil) }
        }
        do {
            try await actions.approve(project, thread)
        } catch {
            if mine == generation { actionError = "\(error)" }
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
        guard ownedRun == nil else {
            actionError = "A run is already going."
            reopenSendBack()
            return
        }
        let handle: RunHandle
        do { handle = try actions.makeRun(project, thread, options) } catch {
            actionError = "The run did not start: \(error)"
            reopenSendBack()
            return
        }
        // The turn is not in the log until the worktree is cut and setup has run: say so until it is.
        var turnNow = 0
        if case .thread(let shown) = screen { turnNow = shown.state.lastTurn }
        (awaitingAfterTurn, awaitingScope) = (turnNow, currentScope)
        setBusy("Starting the run…")
        ownedRun = OwnedRun(handle: handle, project: project, thread: thread)
        applyOwnership()
        Task { [weak self] in
            do {
                try await handle.run()
                // A turn quick enough to end between two polls is never seen to begin: its note is spent all the same.
                if self?.sendingBack == false { self?.sendBackNote = "" }
            } catch { self?.runFailed(error, generation: mine) }
            await self?.runEnded()
        }
    }

    /// The runner the app holds writes the log a moment after it starts: an open turn with no live runner is not a dead one.
    private func applyOwnership() {
        guard runningHere, case .thread(var shown) = screen, shown.run?.phase == .orphaned else { return }
        shown.run?.phase = .working
        screen = .thread(shown)
    }

    private func runEnded() async {
        ownedRun = nil
        stopping = false
        endRunStart()
        await reload()
        // A run that returns leaves its turn ended in the log; one that does not has died without saying how.
        if case .thread(let shown) = screen, shown.run?.phase == .orphaned, actionError == nil {
            actionError = "The run ended without recording how the turn ended. Run again records it as interrupted."
        }
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

    /// The project this app has a run going in, if any.
    var runningProjectPath: String? { ownedRun?.project.root.path }

    /// Whether this window's thread is the one the app is running.
    var runningHere: Bool { ownedRun.map { $0.project == project && $0.thread == currentThread } ?? false }

    /// Asks the turn to end: through the runner this app holds, else the process a terminal's `workbench run` holds. The turn
    /// still ends with a recorded `stopped`; this only asks.
    func stopTurn() async {
        guard let project, let thread = currentThread, !stopping else { return }
        stopping = true
        actionError = nil
        if let owned = ownedRun, owned.project == project, owned.thread == thread {
            await owned.handle.stop()
        } else if await !actions.requestStop(project, thread) {
            stopping = false
            actionError = "Nothing is running this thread."
        }
    }

    func openWorktree() async {
        guard let project, let thread = currentThread else { return }
        actionError = nil
        await working("Opening the worktree…") {
            do { try await actions.openWorktree(project, thread) } catch { actionError = "\(error)" }
        }
    }

    /// The diffs against the base in the editor: every changed file, or the one at `path`.
    func openDiff(path: String? = nil) async {
        guard let project, let thread = currentThread else { return }
        (actionError, actionNote) = (nil, nil)
        await working("Opening the diff…") {
            do { actionNote = try await actions.openDiff(project, thread, path) } catch { actionError = "\(error)" }
        }
    }

    /// A run that could not start (no provider executable, a config that does not load) records no turn, so this is the only
    /// place the person hears of it. An answer for another project is dropped.
    private func runFailed(_ error: Error, generation mine: Int) {
        guard mine == generation else { return }
        endRunStart()
        actionError = "The run did not start: \(error)"
        reopenSendBack()
    }

    func openGoalFile() async {
        guard let project, let thread = currentThread else { return }
        actionError = nil
        do { try await actions.openGoal(project, thread) } catch { actionError = "\(error)" }
    }

    /// Polls every 250 ms while the thread is working and every 2 s otherwise, until `stopPolling`.
    func startPolling() {
        guard polling == nil else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
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
        if busy != nil || ownedRun != nil { return true }
        if case .thread(let snapshot) = screen { return snapshot.attention == .working }
        return false
    }

    // MARK: Doctor

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
