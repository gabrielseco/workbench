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
    private(set) var actionError: String?
    private(set) var starting = false

    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private var currentThread: String?
    @ObservationIgnored private var lastWatch: ProjectLoader.Watch?
    @ObservationIgnored private var polling: Task<Void, Never>?
    @ObservationIgnored private let intervals: (working: Duration, idle: Duration)
    /// Bumped each time another project is opened: an answer for an earlier one (a reload or a doctor run that was still
    /// in flight) is dropped, never shown under the new project.
    @ObservationIgnored private var generation = 0
    /// Seams for tests that need to hold a read or a doctor run half way; the app uses the real ones.
    @ObservationIgnored private let loader: @Sendable (Project) -> ProjectLoader.Loaded
    @ObservationIgnored private let doctorRunner: @Sendable (Project, String?) async -> DoctorChip
    @ObservationIgnored private let goalLoader: @Sendable (Project, String) async -> GoalModel
    @ObservationIgnored private let actions: GoalActions

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
            (project, currentThread, lastWatch, doctor, goal) = (nil, nil, nil, .notRun, nil)
            screen = .notAGitRepository(path: url.path)
            return false
        }
        preferences.projectPath = located.root.path
        generation += 1
        project = located
        doctor = .notRun
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

    private func reload() async {
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
        (screen, currentThread, lastWatch, goal) = (result.screen, result.thread, result.watch, model)
    }

    // MARK: Goal actions

    /// Approves the goal, and only when that worked starts the run: a failed approve starts nothing. The run is core's, started
    /// here and left to the log to report.
    func approveAndRun() async {
        guard let project, let thread = currentThread, !starting else { return }
        let mine = generation
        starting = true
        actionError = nil
        defer { starting = false }
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
        let run = actions.run
        Task { [weak self] in
            do { try await run(project, thread) } catch { self?.runFailed(error, generation: mine) }
        }
    }

    /// A run that could not start (no provider executable, a config that does not load) records no turn, so this is the only
    /// place the person hears of it. An answer for another project is dropped.
    private func runFailed(_ error: Error, generation mine: Int) {
        guard mine == generation else { return }
        actionError = "The run did not start: \(error)"
    }

    func openGoalFile() async {
        guard let project, let thread = currentThread else { return }
        actionError = nil
        do { try await actions.openGoal(project, thread) } catch { actionError = "\(error)" }
    }

    /// Creates a thread from the template; core refuses while another thread is active, and says so.
    func newGoal(name: String) async {
        guard let project, !starting else { return }
        actionError = nil
        do {
            try await actions.newThread(project, name)
        } catch {
            actionError = "\(error)"
            return
        }
        (currentThread, lastWatch) = (nil, nil)
        await reload()
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
