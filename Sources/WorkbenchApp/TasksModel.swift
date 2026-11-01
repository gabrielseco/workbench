import Foundation
import Observation
import WorkbenchCore

/// What the centre shows: the thread screens, or the project's scheduled tasks.
enum WindowMode: String, Equatable, CaseIterable {
    case thread = "Thread"
    case tasks = "Tasks"
}

/// What a mark means, before it is a colour (`Theme` turns it into one): the five meanings of docs/DESIGN.md.
enum TaskTone: Equatable {
    case done, working, idle, needsYou, broken
}

/// How an outcome is told: a word, a symbol and a tone, so colour is never the only signal.
enum TaskOutcomeStyle {
    static func tone(_ outcome: TaskOutcome?) -> TaskTone {
        switch outcome {
        case nil: .working
        case .prOpened?, .reported?: .done
        case .nothingPending?, .nothingToDo?, .skippedProjectBusy?, .skippedAlreadyRunning?, .skippedTooManyOpen?: .idle
        case .staleApproval?: .needsYou
        case .failed?, .budgetExceeded?, .interrupted?: .broken
        }
    }

    static func word(_ outcome: TaskOutcome?) -> String { outcome?.rawValue ?? "running" }

    static func symbol(_ outcome: TaskOutcome?) -> String {
        switch tone(outcome) {
        case .working: "circle.inset.filled"
        case .done: "checkmark.circle.fill"
        case .idle: "minus.circle"
        case .needsYou: "exclamationmark.circle.fill"
        case .broken: "xmark.circle.fill"
        }
    }

    static func tone(_ level: TimerStatusLine.Level) -> TaskTone {
        switch level {
        case .ok: .done
        case .warn: .needsYou
        case .fail: .broken
        }
    }

    static func symbol(_ level: TimerStatusLine.Level) -> String {
        switch level {
        case .ok: "checkmark.circle.fill"
        case .warn: "exclamationmark.circle.fill"
        case .fail: "xmark.circle.fill"
        }
    }

    /// Approval, in words; a task that does not load says so first.
    static func approvalWord(_ summary: TaskSummary) -> String {
        if summary.problem != nil { return "PROBLEM" }
        switch summary.approval {
        case .approved: return "Approved"
        case .stale: return "STALE"
        case .never: return "Not approved"
        }
    }

    static func approvalTone(_ summary: TaskSummary) -> TaskTone {
        if summary.problem != nil { return .broken }
        switch summary.approval {
        case .approved: return .idle
        case .stale, .never: return .needsYou
        }
    }
}

/// One task as the screen shows it: the core's summary and the core's runs, newest first. Nothing here is derived a second time.
struct TaskEntry: Equatable, Identifiable {
    var summary: TaskSummary
    var runs: [TaskHistory.Run]
    /// When the approval now in force was recorded: a STALE state is told apart by it, so a task edited again after a fresh approval
    /// is a new reason.
    var approvedAt: Date?
    var id: String { summary.name }
    var isRunning: Bool { runs.first?.outcome == nil && !runs.isEmpty }
}

/// What the timer card says: the core's lines, or why they could not be read.
enum TimerCard: Equatable {
    case lines([TimerStatusLine])
    case unknown(String)

    /// The worst level among the lines; nil when they cannot be read.
    var worst: TimerStatusLine.Level? {
        guard case .lines(let lines) = self else { return nil }
        if lines.contains(where: { $0.level == .fail }) { return .fail }
        if lines.contains(where: { $0.level == .warn }) { return .warn }
        return .ok
    }

    /// "2 problems · 3 warnings": what is behind the headline, so a closed card still says how much is wrong.
    var counts: String? {
        guard case .lines(let lines) = self else { return nil }
        let fails = lines.filter { $0.level == .fail }.count
        let warns = lines.filter { $0.level == .warn }.count
        let problems = fails > 0 ? "\(fails) problem\(fails == 1 ? "" : "s")" : nil
        let warnings = warns > 0 ? "\(warns) warning\(warns == 1 ? "" : "s")" : nil
        let parts = [problems, warnings].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var headline: String {
        switch worst {
        case .ok?: "Ready for tonight"
        case .warn?: "Will run, check the warnings"
        case .fail?: "Fix before tonight"
        case nil: "unknown"
        }
    }
}

struct TasksSnapshot: Equatable {
    var projectPath: String
    var entries: [TaskEntry]
    var timer: TimerCard
    var readAt: Date
}

/// Reads the tasks of a project from the core and nothing else; read only, nothing is written and no thread is touched.
struct TasksReader: Sendable {
    var read: @Sendable (Project, Date) async throws -> TasksSnapshot

    /// The project's own files, the real timer unless a launch names a stand-in (`WORKBENCH_APP_HOME`, `WORKBENCH_APP_LAUNCHCTL`,
    /// `WORKBENCH_APP_PROBES`, which `scripts/verify-app.sh` sets so a fixture never asks the machine's launchd).
    static func core(environment: [String: String] = ProcessInfo.processInfo.environment) -> TasksReader {
        TasksReader { project, now in
            let entries = try entries(project, now: now)
            let service = timerService(project: project, environment: environment)
            return TasksSnapshot(
                projectPath: project.root.path, entries: entries, timer: await timerCard(service), readAt: now)
        }
    }

    /// The project's tasks and their runs, without the timer's probes: what the menu bar watches. A folder that cannot be read is a
    /// failed read, not "no tasks", so the last good data stays.
    static func entries(_ project: Project, now: Date) throws -> [TaskEntry] {
        let library = TaskLibrary(project: project)
        do { _ = try FileManager.default.contentsOfDirectory(atPath: project.tasksDirectory.path) } catch {
            let missing = (error as NSError).code == NSFileReadNoSuchFileError
            if !missing { throw error }
        }
        return library.names().map { name -> TaskEntry in
            let history = try? TaskRunLog(project: project, name: name).history()
            return TaskEntry(
                summary: library.summary(name, now: now), runs: Array((history?.runs ?? []).reversed()),
                approvedAt: history?.approvedAt)
        }
    }

    /// The core's lines, or `unknown` when the probes (`launchctl`, `pmset`, `fdesetup`) do not answer in time: never a made-up green.
    static func timerCard(_ service: TimerService, limit: Duration = .seconds(45)) async -> TimerCard {
        await withTaskGroup(of: TimerCard.self) { group in
            group.addTask { .lines(await service.status()) }
            group.addTask {
                try? await Task.sleep(for: limit)
                return .unknown("launchctl, pmset or fdesetup did not answer in time")
            }
            let first = await group.next() ?? .unknown("no answer")
            group.cancelAll()
            return first
        }
    }

    static func timerService(project: Project, environment: [String: String]) -> TimerService {
        let home = URL(fileURLWithPath: environment["WORKBENCH_APP_HOME"] ?? NSHomeDirectory(), isDirectory: true)
        let launchctlPath = environment["WORKBENCH_APP_LAUNCHCTL"] ?? "/bin/launchctl"
        let launchctl: GitRunner? =
            FileManager.default.isExecutableFile(atPath: launchctlPath)
            ? GitRunner(
                executable: URL(fileURLWithPath: launchctlPath), environment: ["PATH": "/usr/bin:/bin"], timeout: 30)
            : nil
        let binary = Bundle.main.executableURL ?? URL(fileURLWithPath: "/usr/bin/false")
        var service = TimerService(
            project: project, home: home, workbench: binary, launchctl: launchctl, uid: getuid())
        if let dir = environment["WORKBENCH_APP_PROBES"], !dir.isEmpty {
            let root = URL(fileURLWithPath: dir, isDirectory: true)
            func canned(_ name: String) -> @Sendable () async -> String? {
                { try? String(contentsOf: root.appendingPathComponent(name), encoding: .utf8) }
            }
            service.probes = TimerProbes(sched: canned("sched"), power: canned("power"), fileVault: canned("filevault"))
        }
        return service
    }
}

/// The Tasks screen's state. It re-reads when the app is activated and every `interval` while the screen is shown, keeps the last good
/// read when a read fails, and never writes.
@MainActor @Observable final class TasksModel {
    static let interval: TimeInterval = 30

    private(set) var snapshot: TasksSnapshot?
    /// Why the last read failed; the last good snapshot stays on screen next to it.
    private(set) var error: String?
    var selection: String?
    private(set) var reads = 0

    // What the two buttons are doing. Only they write, and only through `TaskActions` (core).
    /// The approve card: what would run, and why the last try was refused.
    var approving: TaskCardInfo?
    var approveError: String?
    /// The run card (`fix: pr` only): what it may cost and what it does.
    var confirmingRun: TaskCardInfo?
    /// The task a run started here is going for, and what it last said.
    var runningTask: String?
    var runSaid: String?
    /// How the last run started here ended, shown under that task's header until another starts.
    var lastResult: RunOutcome?
    var runningProject: String?
    /// Why a button did nothing (another run going, the task did not load).
    var actionNote: String?
    @ObservationIgnored var stopSwitch: TaskStopSwitch?
    @ObservationIgnored let actions: TaskActions
    @ObservationIgnored private var lastRead: Date?
    /// The project of the newest read asked for; an answer for another one is dropped.
    @ObservationIgnored var latestPath: String?
    @ObservationIgnored private let reader: TasksReader
    @ObservationIgnored private let clock: @Sendable () -> Date

    init(
        reader: TasksReader = .core(), clock: @escaping @Sendable () -> Date = { Date() }, actions: TaskActions = .core
    ) {
        self.reader = reader
        self.clock = clock
        self.actions = actions
    }

    /// The snapshot, only when it is of this project: another project's tasks are never shown under this one.
    func snapshot(for project: Project?) -> TasksSnapshot? {
        guard let project, let snapshot, snapshot.projectPath == project.root.path else { return nil }
        return snapshot
    }

    func selected(in snapshot: TasksSnapshot) -> TaskEntry? {
        if let selection, let entry = snapshot.entries.first(where: { $0.id == selection }) { return entry }
        // The task that most needs a look first: one that did not end well, a stale one, else the first.
        return snapshot.entries.first { TaskOutcomeStyle.tone($0.runs.first?.outcome) == .broken && !$0.runs.isEmpty }
            ?? snapshot.entries.first { $0.summary.approval != .approved || $0.summary.problem != nil }
            ?? snapshot.entries.first
    }

    /// Whether a read is due: the screen is shown and it has not been read for `interval`.
    func isDue(visible: Bool) -> Bool {
        guard visible else { return false }
        guard let lastRead else { return true }
        // A run started here is watched more closely: its row says `running` and then how it ended.
        return clock().timeIntervalSince(lastRead) >= (runningTask == nil ? Self.interval : 3)
    }

    /// Reads now. A failed read leaves the last good snapshot and says why.
    func refresh(_ project: Project?) async {
        guard let project else { return }
        let now = clock()
        lastRead = now
        reads += 1
        latestPath = project.root.path
        do {
            let fresh = try await reader.read(project, now)
            // The project changed while this was reading: its answer is for the one that was left.
            guard latestPath == fresh.projectPath else { return }
            // A selection that is not a task of this project is dropped; one that is (made by a notification) stays.
            if let chosen = selection, !fresh.entries.contains(where: { $0.id == chosen }) { selection = nil }
            snapshot = fresh
            error = nil
        } catch {
            guard latestPath == project.root.path else { return }
            self.error = "\(error)"
        }
    }

    /// The poll and the activation hook call this: reads only when due, or when `force` (the app came to the front).
    func refreshIfDue(_ project: Project?, visible: Bool, force: Bool = false) async {
        guard visible, force || isDue(visible: visible) else { return }
        await refresh(project)
    }
}

/// Dates for the screen, in words that fit a row.
enum TasksText {
    static func when(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let time = date.formatted(.dateTime.hour().minute())
        if calendar.isDate(date, inSameDayAs: now) { return "today \(time)" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "tomorrow \(time)"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "yesterday \(time)"
        }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
    }

    /// The next run: "due now" when the moment has passed (a run missed while off happens once, on the next tick), "manual" for none.
    static func next(_ summary: TaskSummary, now: Date) -> String {
        if summary.problem != nil { return "—" }
        guard summary.schedule != nil else { return "manual" }
        guard summary.approval == .approved else { return "not until approved" }
        guard let due = summary.nextDue else { return "—" }
        return due <= now ? "due now" : when(due, now: now)
    }

    /// The window shows one thread per project (no thread list yet), so a run's thread opens only when it is the one on screen.
    static func canOpenThread(_ run: TaskHistory.Run, onScreen: String?) -> Bool {
        run.thread != nil && run.thread == onScreen
    }

    /// A reason as the core cleans it on the way out, so a stored one that is long or holds control characters is never shown raw.
    static func reason(_ run: TaskHistory.Run) -> String? {
        run.reason.map { TaskExplanation.clean($0, limit: TaskExplanation.maxReason) }.flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// How the last run started from the window ended, and whose it was: a task of the same name in another project is not it.
struct RunOutcome {
    var project: String
    var task: String
    var result: TaskRunResult
}
