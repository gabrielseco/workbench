import Foundation

public enum TaskTrigger: String, Sendable, Equatable {
    /// `task tick`: the schedule said it was due.
    case tick
    /// `task run`: a person asked for it now.
    case manual
}

/// How one run of a task ended, as the run log has it.
public struct TaskRunResult: Sendable, Equatable {
    public var outcome: TaskOutcome
    public var reason: String?
    public var units: [String] = []
    public var thread: String?
    public var pullRequest: String?
    /// False when the run could not write its record: another run holds the task's log, or the log cannot be opened.
    public var recorded = true

    /// Ended the way a run is meant to: it did what it was asked, or found nothing to do.
    public var isDone: Bool {
        switch outcome {
        case .prOpened, .reported, .nothingPending, .nothingToDo: true
        default: false
        }
    }
}

/// Lets a signal handler stop the turn or check a run is in the middle of.
public final class TaskStopSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var runner: ThreadRunner?
    private var requested = false

    public init() {}

    func attach(_ runner: ThreadRunner) async {
        lock.withLock { self.runner = runner }
        if lock.withLock({ requested }) { await runner.stop() }
    }

    public func stop() async {
        let current = lock.withLock { () -> ThreadRunner? in
            requested = true
            return runner
        }
        await current?.stop()
    }
}

/// Runs one task: the guards, the units, then (for `fix: pr`) a thread through the normal path and the pull request. Every run that
/// gets as far as the log ends with a `task.run.ended` that says how, and nothing here throws: a failure is an outcome.
public struct TaskRunner: Sendable {
    public let project: Project
    public let git: GitRunner
    public let gh: GitRunner?
    public var now: @Sendable () -> Date = { Date() }
    public var environment: [String: String] = ProcessInfo.processInfo.environment
    public var runOptions = RunOptions()
    public var stop = TaskStopSwitch()
    public var notice: @Sendable (String) -> Void = { _ in }

    public init(project: Project, git: GitRunner, gh: GitRunner?) {
        self.project = project
        self.git = git
        self.gh = gh
    }

    public func run(_ name: String, trigger: TaskTrigger) async -> TaskRunResult {
        let log = TaskRunLog(project: project, name: name)
        let writer: EventLogWriter
        do {
            writer = try await log.openWriter(now: now)
        } catch EventLogError.alreadyOpen {
            return TaskRunResult(
                outcome: .skippedAlreadyRunning, reason: "another run of this task is in progress", recorded: false)
        } catch {
            return TaskRunResult(outcome: .failed, reason: "the run log cannot be opened: \(error)", recorded: false)
        }
        let history: TaskHistory
        do { history = try log.history() } catch {
            await writer.close()
            return TaskRunResult(outcome: .failed, reason: "the run log is damaged: \(error)", recorded: false)
        }
        // Without a durable start nothing is spent: a run that cannot say it began could not say how it ended.
        do { try await writer.append(.taskRunStarted, data: ["trigger": .string(trigger.rawValue)]) } catch {
            await writer.close()
            return TaskRunResult(
                outcome: .failed, reason: "the run could not be recorded, so nothing was started: \(error)", recorded: false)
        }
        var result = await execute(name, history: history, writer: writer)
        var data: [String: JSONValue] = [
            "outcome": .string(result.outcome.rawValue), "units": .array(result.units.map { .string($0) }),
        ]
        if let reason = result.reason { data["reason"] = .string(reason) }
        if let thread = result.thread { data["thread"] = .string(thread) }
        if let url = result.pullRequest { data["pr"] = .string(url) }
        do { try await writer.append(.taskRunEnded, data: .object(data)) } catch {
            result.recorded = false
            result.reason = (result.reason.map { $0 + "; " } ?? "") + "the end of the run could not be recorded: \(error)"
        }
        await writer.close()
        return result
    }

    private func fail(_ reason: String, units: [String] = [], thread: String? = nil) -> TaskRunResult {
        TaskRunResult(outcome: .failed, reason: reason, units: units, thread: thread)
    }

    private func execute(_ name: String, history: TaskHistory, writer: EventLogWriter) async -> TaskRunResult {
        let library = TaskLibrary(project: project)
        let loaded: LoadedTask
        do { loaded = try library.load(name) } catch { return fail("\(error)") }
        let task = loaded.definition

        switch TaskApproval.state(approvedHash: history.approvedHash, currentHash: loaded.hash) {
        case .approved: break
        case .never:
            return TaskRunResult(
                outcome: .staleApproval, reason: "the task was never approved: workbench task approve \(name)")
        case .stale:
            return TaskRunResult(
                outcome: .staleApproval, reason: "the task changed since it was approved: workbench task approve \(name)")
        }
        let store = ThreadStore(project: project)
        if let active = store.activeThreadID() { return busy(active) }
        if (try? store.requireNoDoctor()) == nil { return busy("a doctor run") }

        var units: [TaskUnit] = []
        if let script = task.pending {
            let all: [TaskUnit]
            do {
                all = try await PendingUnits.run(script: script, project: project, environment: environment)
            } catch { return fail("\(error)") }
            let states = await TaskPullRequests.states(units: history.unitsWithThreads, gh: gh, project: project)
            units = PendingUnits.select(units: all, history: history, pullRequests: states, batch: task.batch)
            if units.isEmpty {
                return TaskRunResult(outcome: .nothingPending, reason: "\(all.count) unit(s) listed, none left to do")
            }
        }
        let ids = units.map(\.id)

        if task.fix == .report {
            let list = ids.isEmpty ? "run once" : "would take " + ids.joined(separator: ", ")
            return TaskRunResult(outcome: .reported, reason: list, units: ids)
        }
        return await runThread(name: name, loaded: loaded, units: units, writer: writer)
    }

    private func busy(_ what: String) -> TaskRunResult {
        TaskRunResult(
            outcome: .skippedProjectBusy, reason: "\(what) is still active: finish or abandon it (one thread at a time)")
    }

    // MARK: fix: pr

    private func runThread(name: String, loaded: LoadedTask, units: [TaskUnit], writer: EventLogWriter) async -> TaskRunResult {
        let task = loaded.definition
        let ids = units.map(\.id)
        let config: Config
        do { config = try Config.load(from: project.configURL) } catch {
            return fail("the project's config cannot be read: \(error)", units: ids)
        }
        // Accepting unattended work needs something that checked it.
        guard config.checkCommand != nil else {
            return fail(
                "no check configured: set check_command in .workbench/config.toml, so the work is checked before it is accepted",
                units: ids)
        }
        let prompt: String
        do {
            let inputs = try TaskFiles(project: project).inputs(task.inputs)
            prompt = try TaskPrompt.build(task: loaded, inputs: inputs, units: units)
        } catch { return fail("\(error)", units: ids) }

        let service = ThreadService(project: project, git: git)
        let id: String
        do {
            var settings = GoalSettings(quick: true)
            settings.budgetUSD = task.budgetUSD
            id = try await service.newThread(
                name: TaskPrompt.threadName(task: name, units: units), config: config,
                body: GoalBody(
                    request: prompt, criteria: [],
                    outOfScope: ["Pushing, merging or opening a pull request: Workbench does that after the check passes."]),
                settings: settings, title: TaskPrompt.title(task: name, units: units))
        } catch ThreadStoreError.activeThreadExists(let active) {
            return busy(active)
        } catch { return fail("the thread could not be created: \(error)", units: ids) }

        do { _ = try await service.approve(id: id, config: config) } catch {
            _ = try? await service.abandon(id: id)
            return fail("the task's goal could not be approved: \(error)", units: ids)
        }

        // Before any work: which units this thread is for, so a run that dies later is still known to have had them.
        do {
            try await writer.append(
                .taskRunThread,
                data: ["thread": .string(id), "units": .array(ids.map { .string($0) }), "hash": .string(loaded.hash)])
        } catch {
            _ = try? await service.abandon(id: id)
            return fail("the run could not be recorded, so nothing was started: \(error)", units: ids)
        }
        // From here the thread is real: when something goes wrong it is left as it is, for a person to look at.
        let runner = ThreadRunner(project: project, threadID: id, git: git) { _ in }
        await stop.attach(runner)
        let report: TurnReport
        do { report = try await runner.run(runOptions) } catch {
            return fail("the turn could not run: \(error)", units: ids, thread: id)
        }
        notice("turn \(report.turn) ended: \(report.result.rawValue)")
        let why = explanation(report, id: id, service: service)
        guard report.result == .succeeded else {
            let outcome: TaskOutcome = report.result == .budgetExceeded ? .budgetExceeded : .failed
            return TaskRunResult(
                outcome: outcome, reason: why.reason("the turn ended \(report.result.rawValue); thread \(id) is left for you"),
                units: ids, thread: id)
        }
        guard let check = report.check, check.result == .passed else {
            let what = report.check.map { "the check \($0.result.rawValue)" } ?? "the check did not run"
            return fail(why.reason("\(what); thread \(id) is left for you", includeCheck: true), units: ids, thread: id)
        }
        if let verifier = report.verifier, !verifier.ok {
            let what = verifier.reason ?? "no reason"
            return fail(
                why.reason("the verifier did not pass (\(what)); thread \(id) is left for you"), units: ids, thread: id)
        }
        return await acceptAndShip(name: name, id: id, config: config, service: service, units: ids, explanation: why)
    }

    /// The agent's last message, the commands the turn was denied and, for a failed check, the end of its output.
    private func explanation(_ report: TurnReport, id: String, service: ThreadService) -> TaskExplanation {
        var denied: [String] = []
        if report.permissionDenials > 0, let candidates = try? service.grantCandidates(id: id) {
            denied = candidates.compactMap(\.input)
        }
        var tail: [String] = []
        if let check = report.check, check.result != .passed {
            let url = project.threadDirectory(id).appendingPathComponent(check.outputRef)
            if let data = try? Data(contentsOf: url) {
                let text = String(decoding: data.suffix(8 << 10), as: UTF8.self)
                tail = text.split(separator: "\n", omittingEmptySubsequences: true).suffix(TaskExplanation.maxCheckLines)
                    .map(String.init)
            }
        }
        return TaskExplanation(message: report.summary, denied: denied, checkTail: tail)
    }

    private func acceptAndShip(
        name: String, id: String, config: Config, service: ThreadService, units: [String], explanation: TaskExplanation
    ) async -> TaskRunResult {
        do { _ = try await service.accept(id: id, by: "task:\(name)") } catch ThreadServiceError.nothingToAccept {
            // An expected result, most often for a task that checks something and finds it fine: not a failure, and not a thread
            // to leave behind, since the next run would be skipped for it.
            _ = try? await service.abandon(id: id)
            return TaskRunResult(
                outcome: .nothingToDo, reason: explanation.reason("the agent changed nothing, so there is nothing to ship"),
                units: units, thread: id)
        } catch {
            return fail("the work could not be accepted: \(error); thread \(id) is left for you", units: units, thread: id)
        }
        let stranded = "thread \(id) is accepted but not shipped: workbench ship"
        let plan: ShipPlan
        do { plan = try await service.shipPreflight(id: id, gh: gh) } catch {
            return fail("\(error); \(stranded)", units: units, thread: id)
        }
        // A description written from the diff, or no pull request: the fallback body is built from the goal's request, which for a task
        // holds its skill and its input files.
        let described: PRDescribeResult
        do {
            described = try await service.describePR(plan: plan, config: config, environment: runOptions.parentEnvironment)
        } catch {
            return fail("the change could not be described: \(error); \(stranded)", units: units, thread: id)
        }
        guard let description = described.description else {
            let why = described.fallback ?? "no reason"
            return fail("the change could not be described (\(why)); \(stranded)", units: units, thread: id)
        }
        do {
            let outcome = try await service.publishShip(
                id: id, gh: gh, plan: plan, description: description,
                options: ShipPublishOptions(keepWorktree: false, skipScreenshots: true))
            return TaskRunResult(outcome: .prOpened, reason: nil, units: units, thread: id, pullRequest: outcome.pr.url)
        } catch {
            return fail("\(error); \(stranded)", units: units, thread: id)
        }
    }
}
