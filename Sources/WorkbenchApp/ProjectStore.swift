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

/// What one full read of the project found, and what `stat` said just after it.
private struct Loaded: Sendable {
    var screen: ProjectScreen
    var thread: String?
    var watch: ProjectLoader.Watch
}

/// The one store of a window: the project, the screen derived from its newest thread's log, and the Doctor chip. It holds
/// no thread state outside the log and the chosen repo path, and it reads the log off the main actor, only when `stat`
/// says it changed.
@MainActor @Observable final class ProjectStore {
    private(set) var screen: ProjectScreen
    private(set) var project: Project?
    private(set) var doctor: DoctorChip = .notRun

    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private var currentThread: String?
    @ObservationIgnored private var lastWatch: ProjectLoader.Watch?
    @ObservationIgnored private var polling: Task<Void, Never>?
    @ObservationIgnored private let intervals: (working: Duration, idle: Duration)

    /// `screen` is for previews and tests that show a fixed state without a project on disk.
    init(
        preferences: Preferences, screen: ProjectScreen = .noProject, project: Project? = nil,
        intervals: (working: Duration, idle: Duration) = (.milliseconds(250), .seconds(2))
    ) {
        self.preferences = preferences
        self.screen = screen
        self.project = project
        self.intervals = intervals
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
            screen = .notAGitRepository(path: url.path)
            return false
        }
        preferences.projectPath = located.root.path
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
        let thread = currentThread
        let now = await Task.detached { ProjectLoader.watch(project: project, thread: thread) }.value
        if now != lastWatch { await reload() }
    }

    private func reload() async {
        guard let project else { return }
        let result = await Task.detached { () -> Loaded in
            let loaded = ProjectLoader.load(project: project)
            return Loaded(
                screen: loaded.screen, thread: loaded.thread,
                watch: ProjectLoader.watch(project: project, thread: loaded.thread))
        }.value
        (screen, currentThread, lastWatch) = (result.screen, result.thread, result.watch)
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
    /// the work is core's, awaited here.
    func runDoctor() async {
        guard let project, doctor != .running else { return }
        doctor = .running
        let clock = ContinuousClock()
        let started = clock.now
        do {
            let git = try GitRunner.discover()
            var base = "main"
            if case .thread(let snapshot) = screen, let known = snapshot.base {
                base = known
            } else {
                base = await ThreadService(project: project, git: git).defaultBase()
            }
            let report = try await Doctor(project: project, git: git).run(base: base)
            let elapsed = started.duration(to: clock.now)
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            switch report.verdict {
            case .passed: doctor = .healthy(seconds: seconds)
            case .stepsFailed: doctor = .problem("The declared setup or check failed")
            case .stopped: doctor = .problem("Doctor was stopped")
            case .cleanupFailed(let problem): doctor = .problem(problem)
            }
        } catch {
            doctor = .problem("\(error)")
        }
    }
}
