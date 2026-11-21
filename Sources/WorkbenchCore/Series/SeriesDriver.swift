import Foundation

/// One `workbench` command the driver ran, in a step's project.
public struct SeriesCommandResult: Sendable, Equatable {
    public var exit: Int32
    public var stdout: [String]
    public var stderr: String

    public init(exit: Int32, stdout: [String] = [], stderr: String = "") {
        (self.exit, self.stdout, self.stderr) = (exit, stdout, stderr)
    }
}

/// How the driver runs a `workbench` command. The real one starts this binary; a test supplies its own.
public protocol SeriesCommandRunner: Sendable {
    func run(
        _ arguments: [String], in project: URL, environment: [String: String], output: @Sendable (String) -> Void
    ) async -> SeriesCommandResult
    /// Ends the command that is running, cleanly (the child ends its own turn). Idempotent.
    func stop()
}

/// Starts `workbench` through `ProcessRunner`: its own process group, stdin `/dev/null`, the environment given and nothing else.
public final class WorkbenchProcessRunner: SeriesCommandRunner, @unchecked Sendable {
    public static let commandTimeout: TimeInterval = 6 * 3600
    public static let killGrace: TimeInterval = 60

    private let binary: URL
    private let baseEnvironment: [String: String]
    private let lock = NSLock()
    private var current: ProcessRun?
    private var stopRequested = false

    public init(binary: URL, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.binary = binary
        baseEnvironment = environment
    }

    public func stop() {
        let run = lock.withLock {
            stopRequested = true
            return current
        }
        run?.stop()
    }

    public func run(
        _ arguments: [String], in project: URL, environment: [String: String], output: @Sendable (String) -> Void
    ) async -> SeriesCommandResult {
        let merged = baseEnvironment.merging(environment) { _, new in new }
        var request = SpawnRequest(
            executable: binary, arguments: arguments, environment: merged, workingDirectory: project,
            timeout: Self.commandTimeout)
        // The child ends its own turn on SIGTERM and gives a stubborn agent 5 s before it kills it: this one waits longer, so the
        // child's `turn.ended` is written before anything is killed.
        request.killGrace = Self.killGrace
        let run: ProcessRun
        do { run = try ProcessRunner.start(request) } catch {
            return SeriesCommandResult(exit: 1, stderr: "could not start \(binary.lastPathComponent): \(error)")
        }
        let already = lock.withLock {
            current = run
            return stopRequested
        }
        if already { run.stop() }
        var lines: [String] = []
        var exit: Int32 = 1
        var stderr = ""
        for await event in run.events {
            switch event {
            case .line(let line):
                lines.append(line)
                output(line)
            case .exited(let done):
                if case .exited(let code) = done.termination { exit = code }
                stderr = done.stderrTail
            default: break
            }
        }
        lock.withLock { current = nil }
        return SeriesCommandResult(exit: exit, stdout: lines, stderr: stderr)
    }
}

public enum SeriesRunResult: Sendable, Equatable {
    /// Every step is clean.
    case finished
    /// A step stopped (a command failed, the budget was reached, the person stopped it): nothing new starts.
    case stopped(step: Int, reason: String)
    /// Nothing can start and nothing is stopped: a step waits for something that is not the driver's to do (a person, CI).
    case waiting(step: Int, reason: String)
}

public enum SeriesDriverError: Error, Equatable, Sendable, CustomStringConvertible {
    case notApproved(SeriesApproval.State)
    case alreadyRunning

    public var description: String {
        switch self {
        case .notApproved(.stale): "the series changed since it was approved: workbench series approve <name>"
        case .notApproved: "the series is not approved: workbench series approve <name>"
        case .alreadyRunning: "another `series run` of this series is running (run.lock is held)"
        }
    }
}

/// Runs a series (docs/plan/P27-series.md): starts each ready step by running `workbench` in the step's project, one step at a
/// time, then reads the states again. Every command is the one a person would type, so the review loop, the timeouts and the
/// budgets are the ones those commands already have. It never retries, never merges and starts nothing once a step is stopped.
public struct SeriesDriver: Sendable {
    public let library: SeriesLibrary
    public var commands: SeriesCommandRunner
    /// The states of the steps, read fresh each time. The default asks the threads and `gh`.
    public var states: @Sendable (LoadedSeries) async -> [Int: SeriesStepState]
    public var now: @Sendable () -> Date = { Date() }
    public var say: @Sendable (String) -> Void = { _ in }
    /// After a step's commands, how long to wait for its checks to finish, and how often to look.
    public var settleTimeout: TimeInterval = 45 * 60
    public var settleInterval: TimeInterval = 30
    public var sleep: @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1e9)) }

    public init(library: SeriesLibrary, commands: SeriesCommandRunner, git: GitRunner, gh: GitRunner?) {
        self.library = library
        self.commands = commands
        states = { await library.states($0, git: git, gh: gh) }
    }

    public init(
        library: SeriesLibrary, commands: SeriesCommandRunner,
        states: @escaping @Sendable (LoadedSeries) async -> [Int: SeriesStepState]
    ) {
        self.library = library
        self.commands = commands
        self.states = states
    }

    public func run(_ name: String) async throws -> SeriesRunResult {
        // One run at a time: two would each start the same step.
        let lock = try Self.acquire(library.project.seriesDirectory(name).appendingPathComponent("run.lock"))
        defer { close(lock) }
        let log = SeriesStepLog(project: library.project, series: name)
        while true {
            // Read again each round: a goal file or the series changed while a step ran is not what was approved.
            let loaded = try library.load(name)
            let approval = library.state(loaded)
            guard approval == .approved else { throw SeriesDriverError.notApproved(approval) }
            let current = await states(loaded)
            if let stopped = SeriesScheduler.stoppedStep(loaded.definition, states: current) {
                return .stopped(step: stopped.step, reason: stopped.reason)
            }
            if loaded.definition.steps.allSatisfy({ current[$0.number]?.isClean == true }) { return .finished }
            guard let next = SeriesScheduler.ready(loaded.definition, states: current).first,
                let step = loaded.definition.steps.first(where: { $0.number == next })
            else { return Self.waiting(loaded.definition, current) }
            if let reason = await execute(step, loaded: loaded, log: log) {
                return .stopped(step: step.number, reason: reason)
            }
            if let reason = await settle(step, loaded: loaded) { return .waiting(step: step.number, reason: reason) }
        }
    }

    /// Takes `run.lock` without waiting; the descriptor is closed (and the lock released) by the caller, or when the process ends.
    private static func acquire(_ url: URL) throws -> Int32 {
        let fd = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            if fd >= 0 { close(fd) }
            throw SeriesDriverError.alreadyRunning
        }
        return fd
    }

    /// After a step's commands its checks may still be running: look until they are done or the time is up. Returns why the series
    /// cannot go on when they are not; nil when the step is no longer waiting on time alone (clean, or anything else: the next
    /// round reads it).
    private func settle(_ step: SeriesStep, loaded: LoadedSeries) async -> String? {
        var waited: TimeInterval = 0
        while true {
            let state = (await states(loaded))[step.number] ?? .pending
            guard SeriesScheduler.isTransient(state) else { return nil }
            guard waited < settleTimeout else {
                guard case .waiting(let thread, let reason) = state else { return nil }
                return "\(thread): \(reason) after \(Int(settleTimeout / 60)) minutes"
            }
            say("step \(step.number): waiting for its checks")
            await sleep(settleInterval)
            waited += settleInterval
        }
    }

    private static func waiting(_ definition: SeriesDefinition, _ states: [Int: SeriesStepState]) -> SeriesRunResult {
        for step in definition.steps {
            switch states[step.number] {
            case .waiting(let thread, let reason)?: return .waiting(step: step.number, reason: "\(thread): \(reason)")
            case .running(let thread)?:
                return .waiting(
                    step: step.number,
                    reason: "thread \(thread) has not opened its pull request: finish it with next, run, accept and ship")
            default: continue
            }
        }
        return .waiting(step: 0, reason: "no step can start")
    }

    /// Runs one step's commands; returns why it stopped, nil when every command succeeded.
    private func execute(_ step: SeriesStep, loaded: LoadedSeries, log: SeriesStepLog) async -> String? {
        guard let root = loaded.projects[step.number], let goal = loaded.goals[step.number],
            let goalText = loaded.goalTexts[step.number]
        else { return "the step has no project" }
        if let reason = await reconcile(step, loaded: loaded, log: log) { return reason }
        let records = log.read()
        if let reason = budgetReason(step, loaded: loaded, goal: goal, root: root, records: records) { return reason }
        var environment: [String: String] = [:]
        for pair in step.env {
            switch pair.value {
            case .literal(let value): environment[pair.name] = value
            case .stepBranch(let n):
                guard let parent = records[n]?.thread else {
                    return "env \(pair.name) names step \(n), which has no thread"
                }
                environment[pair.name] = "origin/" + shippedBranch(project: loaded.projects[n] ?? root, thread: parent)
            }
        }
        // The goal the thread is made from is the text that was approved (the one this round read and hashed), not whatever the
        // file holds a moment later.
        let snapshot: URL
        do { snapshot = try writeSnapshot(goalText, series: loaded.definition.name, step: step.number) } catch {
            return "the approved goal could not be copied for the step: \(error)"
        }
        var create = ["goal", "new", "\(loaded.definition.name)-\(step.number)", "--from", snapshot.path]
        switch step.base {
        case .after(let n):
            guard let parent = records[n]?.thread else { return "base: after \(n), which has no thread" }
            create += ["--after", parent]
        case .branch(let branch?): create += ["--base", branch]
        case .branch(nil): break
        }
        let started = ISO8601DateFormatter().string(from: now())
        // Written before the thread exists: a driver that dies between `goal new` and the record below would otherwise make a
        // second thread for this step. The next run finds the first one (`reconcile`).
        do { try log.markStarting(step: step.number, at: started) } catch { return "the step could not be recorded: \(error)" }
        say("step \(step.number): \(create.joined(separator: " "))")
        let made = await commands.run(create, in: root, environment: environment, output: say)
        let created = made.stdout.compactMap { $0.hasPrefix("created ") ? String($0.dropFirst("created ".count)) : nil }
        guard made.exit == 0, let id = created.first, SafeNames.isThreadID(id) else {
            if made.exit != 0 { try? log.markStarting(step: step.number, at: started, starting: false) }
            return made.exit != 0 ? Self.failure("goal new", made) : "goal new did not print the thread it created"
        }
        do { try log.append(SeriesRecord(step: step.number, thread: id, at: started)) } catch {
            return "the step's thread \(id) could not be recorded: \(error)"
        }
        let title = goal.title ?? "series \(loaded.definition.name) step \(step.number)"
        // `ship --review-loop` cannot be combined with `--watch`; the checks are waited for afterwards (`settle`).
        let sequence: [(String, [String])] = [
            ("goal approve", ["goal", "approve", id]),
            ("run", ["run", "--thread", id]),
            ("accept", ["accept", "--thread", id, "-m", "chore: \(title)", "--yes"]),
            ("ship", ["ship", "--thread", id, "--yes", "--review-loop"]),
        ]
        for (label, arguments) in sequence {
            say("step \(step.number): workbench \(arguments.joined(separator: " "))")
            let result = await commands.run(arguments, in: root, environment: environment, output: say)
            guard result.exit == 0 else {
                let reason = Self.failure(label, result)
                // Recorded so `status` says so while the thread has no pull request; with one, its own state is read.
                try? log.append(SeriesRecord(step: step.number, thread: id, at: started, stopped: reason))
                return reason
            }
        }
        return nil
    }

    /// A start marker with no thread recorded after it: the earlier run died around `goal new`. Adopts the one thread it made, or
    /// clears the marker when it made none; several threads are for a person to sort out.
    private func reconcile(_ step: SeriesStep, loaded: LoadedSeries, log: SeriesStepLog) async -> String? {
        guard let marked = log.starting()[step.number], let root = loaded.projects[step.number] else { return nil }
        let suffix = "-\(loaded.definition.name)-\(step.number)"
        let project = Project(root: root)
        let found = ((try? FileManager.default.contentsOfDirectory(atPath: project.threadsDirectory.path)) ?? [])
            .filter { $0.hasSuffix(suffix) && SafeNames.isThreadID($0) }.sorted()
        switch found.count {
        case 0:
            try? log.markStarting(step: step.number, at: marked, starting: false)
            return nil
        case 1:
            try? log.append(SeriesRecord(step: step.number, thread: found[0], at: marked))
            return "step \(step.number) had been started by an earlier run that died: its thread \(found[0]) is recorded now; "
                + "run the series again"
        default:
            let names = found.joined(separator: ", ")
            return "step \(step.number) was started by an earlier run that died, and several threads match (\(names)): "
                + "record the right one in steps.jsonl"
        }
    }

    /// A step starts only when what is left of the series budget covers its goal's own budget, so the series cannot spend past
    /// `budget_usd` in one step (the follow-up threads of a review round have their own caps and are not counted).
    private func budgetReason(
        _ step: SeriesStep, loaded: LoadedSeries, goal: GoalCopy, root: URL, records: [Int: SeriesRecord]
    ) -> String? {
        guard let budget = loaded.definition.budgetUSD else { return nil }
        let limit = NSDecimalNumber(decimal: budget).doubleValue
        let spent = spentUSD(loaded, records: records) ?? 0
        let config = try? Config.load(from: Project(root: root).configURL)
        let wanted = (goal.settings.budgetUSD ?? config?.defaultBudgetUSD).map { NSDecimalNumber(decimal: $0).doubleValue }
        if spent >= limit {
            return "the series budget of \(budget) USD is reached (\(String(format: "%.2f", spent)) USD spent)"
        }
        if let wanted, spent + wanted > limit {
            return "the goal's budget of \(wanted) USD does not fit in what is left of the series budget "
                + "(\(String(format: "%.2f", limit - spent)) of \(budget) USD)"
        }
        return nil
    }

    private func writeSnapshot(_ text: String, series: String, step: Int) throws -> URL {
        let directory = library.project.seriesDirectory(series).appendingPathComponent(".snapshots")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("step-\(step).md")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func failure(_ label: String, _ result: SeriesCommandResult) -> String {
        let tail = result.stderr.split(separator: "\n").last.map(String.init) ?? result.stdout.last ?? "no output"
        return "`\(label)` exited \(result.exit): \(String(tail.prefix(300)))"
    }

    /// The branch a step's pull request is on: `push_to` when its goal continued one, else `workbench/<thread>`.
    func shippedBranch(project: URL, thread: String) -> String {
        let other = Project(root: project)
        let goal = (try? String(contentsOf: other.goalURL(thread), encoding: .utf8)).flatMap { try? GoalFile.parse($0).goal }
        return goal?.pushTo ?? WorktreeManager.branch(for: thread)
    }

    /// What the steps' threads have cost so far (the follow-up threads of a review round are not counted: each is capped by its
    /// own goal). Nil when nothing has been spent.
    func spentUSD(_ loaded: LoadedSeries, records: [Int: SeriesRecord]) -> Double? {
        var total = 0.0
        for (number, record) in records {
            guard let root = loaded.projects[number] else { continue }
            total += ThreadStore(project: Project(root: root)).state(of: record.thread).totalCostUSD
        }
        return total > 0 ? total : nil
    }
}
