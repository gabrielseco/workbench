import Foundation

public enum DoctorError: Error, Equatable, CustomStringConvertible {
    case noConfig(String)
    case threadActive(String)
    case invalidBase(String)
    case alreadyRunning

    public var description: String {
        switch self {
        case .alreadyRunning: "another `workbench doctor` is running in this project"
        case .noConfig(let path): "no config at \(path): run `workbench init` first"
        case .threadActive(let id):
            "thread \(id) is still active; doctor would run a second check next to it. End it (accept, discard, abandon) first"
        case .invalidBase(let base): "'\(base)' is not a usable branch name"
        }
    }
}

/// An exclusive, non-blocking lock on the `.workbench` directory itself, so no file is left behind. Doctor
/// holds it for its whole run; creating a thread takes and drops it, so the two never run checks together.
enum ProjectLock {
    static func acquire(_ project: Project) throws -> Int32 {
        let fd = open(project.workbenchDirectory.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw DoctorError.noConfig(project.configURL.path) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw DoctorError.alreadyRunning
        }
        return fd
    }

    static func release(_ fd: Int32) { close(fd) }
}

/// How one declared command did when doctor ran it.
public struct DoctorStep: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        case passed
        case failed(how: String)
        case timedOut
        case stopped
        /// Not run, with why ("setup failed", "interrupted").
        case skipped(String)
        /// The config does not declare it.
        case notDeclared
    }

    public var command: String?
    public var outcome: Outcome
    public var durationMs: Int?
    /// The last lines of its output, for a step that did not pass.
    public var tail: String
    /// Setup only: a hint that the environment allowlist may be the cause.
    public var hint: String
}

public struct DoctorReport: Sendable, Equatable {
    public var base: String
    /// Where `claude_path` resolved, or nil.
    public var claude: String?
    public var claudePath: String
    /// The `model` in the config, or nil for the CLI's own default.
    public var model: String?
    /// `Bash` is among the available tools, so a run can call the check at all.
    public var bashAvailable: Bool
    /// What a run is allowed for the check, `Bash(<command>:*)`.
    public var checkPattern: String?
    /// `[tools].denied` names `Bash` or the check's own pattern, so a run could not call it.
    public var checkDenied = false
    public var setup: DoctorStep
    public var check: DoctorStep
    /// Set when the throwaway worktree could not be removed, with what to run by hand.
    public var cleanupProblem: String?

    /// Everything declared passed and nothing was left behind. A step the config does not declare is not a
    /// failure.
    public var passed: Bool {
        cleanupProblem == nil
            && [setup, check].allSatisfy {
            switch $0.outcome {
                case .passed, .notDeclared: true
                default: false
                }
            }
    }

    public var wasStopped: Bool {
        [setup, check].contains { if case .stopped = $0.outcome { true } else { false } }
    }
}

/// Proves the declared config works before any goal exists: runs `setup_command` then `check_command`
/// in a throwaway worktree at the base, through the machinery and environment a thread uses.
///
/// It runs only what the config declares and writes nothing to the project: the worktree and its branch are
/// removed on every path, and the events go to a log in a temporary directory that is deleted too.
public final class Doctor: @unchecked Sendable {
    /// The reserved id of the throwaway worktree. A thread's id is `g-<day>-<name>`, so it cannot collide, and
    /// a leftover from a crash is found by this fixed name and removed by the next run.
    public static let worktreeID = "doctor"

    public struct Options: Sendable {
        public var environment: [String: String] = ProcessInfo.processInfo.environment
        public var setupTimeout: TimeInterval = SetupRunner.defaultTimeout
        /// Same default a goal gives a turn (30 minutes), which is also what bounds the check in a thread.
        public var checkTimeout: TimeInterval = 30 * 60
        public var killGrace: TimeInterval = 5
        public init() {}
    }

    private let project: Project
    private let git: GitRunner
    private let store: ThreadStore
    private let lock = NSLock()
    private var current: ProcessRun?
    private var stopRequested = false

    public init(project: Project, git: GitRunner) {
        self.project = project
        self.git = git
        self.store = ThreadStore(project: project)
    }

    /// Asks the running step to end; the rest is skipped and the worktree still goes.
    public func stop() {
        lock.lock()
        stopRequested = true
        let run = current
        lock.unlock()
        run?.stop()
    }

    private func attach(_ process: ProcessRun) {
        lock.lock()
        current = process
        let stopNow = stopRequested
        lock.unlock()
        if stopNow { process.stop() }
    }

    private var isStopRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopRequested
    }

    public func run(base: String, options: Options = Options()) async throws -> DoctorReport {
        guard FileManager.default.fileExists(atPath: project.configURL.path) else {
            throw DoctorError.noConfig(project.configURL.path)
        }
        guard SafeNames.isBranchName(base) else { throw DoctorError.invalidBase(base) }
        if let active = store.activeThreadID() { throw DoctorError.threadActive(active) }
        let config = try Config.load(from: project.configURL)

        let claude = ExecutableResolver.resolve(config.claudePath, searchPath: options.environment["PATH"])
        let bash = config.tools.available.contains("Bash")
        var report = DoctorReport(
            base: base, claude: claude?.path, claudePath: config.claudePath, model: config.model,
            bashAvailable: bash, checkPattern: config.checkCommand.map { "Bash(\($0):*)" },
            checkDenied: config.checkCommand.map {
                config.tools.denied.contains("Bash") || config.tools.denied.contains("Bash(\($0):*)")
            } ?? false,
            setup: DoctorStep(command: config.setupCommand, outcome: .notDeclared, tail: "", hint: ""),
            check: DoctorStep(command: config.checkCommand, outcome: .notDeclared, tail: "", hint: ""))
        guard config.setupCommand != nil || config.checkCommand != nil else { return report }

        // One doctor at a time: a second would otherwise remove the first one's live worktree as a "leftover".
        let lock = try ProjectLock.acquire(project)
        defer { ProjectLock.release(lock) }
        let manager = WorktreeManager(repoRoot: project.root, git: git)
        try await removeLeftover(manager)
        let worktree: Worktree
        do {
            worktree = try await manager.create(threadID: Self.worktreeID, base: base)
        } catch {
            // `worktree add` can register the worktree and then fail (a post-checkout hook, say).
            try? await removeLeftover(manager)
            throw error
        }

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("workbench-doctor-\(UUID().uuidString)")
        let result: Result<DoctorReport, Error>
        do {
            result = .success(
                try await runSteps(report, config: config, worktree: worktree.path, scratch: scratch, options: options))
        } catch {
            result = .failure(error)
        }
        // Removed on every path, also after an error and after a stop.
        try? FileManager.default.removeItem(at: scratch)
        var cleanupProblem: String?
        do {
            try await manager.remove(threadID: Self.worktreeID, force: true, deleteBranch: true)
        } catch {
            cleanupProblem =
                "could not remove the throwaway worktree (\(error)). Remove it by hand: "
                + "git worktree remove --force --force \(worktree.path) && git branch -D "
                + WorktreeManager.branch(for: Self.worktreeID)
        }
        report = try result.get()
        report.cleanupProblem = cleanupProblem
        return report
    }

    private func removeLeftover(_ manager: WorktreeManager) async throws {
        if manager.exists(Self.worktreeID) {
            try await manager.remove(threadID: Self.worktreeID, force: true, deleteBranch: false)
        }
        if try await manager.branchExists(Self.worktreeID) {
            try await manager.deleteBranch(threadID: Self.worktreeID)
        }
    }

    private func runSteps(
        _ initial: DoctorReport, config: Config, worktree: URL, scratch: URL, options: Options
    ) async throws -> DoctorReport {
        let log = try EventLogWriter.open(at: scratch.appendingPathComponent("events.jsonl"))
        do {
            let report = try await execute(
                initial, config: config, worktree: worktree, scratch: scratch, options: options, log: log)
            await log.close()
            return report
        } catch {
            await log.close()
            throw error
        }
    }

    private func execute(
        _ initial: DoctorReport, config: Config, worktree: URL, scratch: URL, options: Options,
        log: EventLogWriter
    ) async throws -> DoctorReport {
        var report = initial
        let environment = config.childEnvironment(from: options.environment)

        if let command = config.setupCommand {
            let output = scratch.appendingPathComponent("setup.log")
            let setup = try await SetupRunner(
                command: command, worktree: worktree, environment: environment,
                timeout: options.setupTimeout, killGrace: options.killGrace
            ).run(outputURL: output, log: log) { [self] in attach($0) }
            report.setup = Self.step(
                command: command, result: setup.result, how: setup.how, durationMs: setup.durationMs, output: output,
                hint: ThreadRunner.envHint(setup))
        }

        guard let command = config.checkCommand else { return report }
        if case .passed = report.setup.outcome {} else if report.setup.command != nil {
            let why = isStopRequested ? "interrupted" : "setup did not pass"
            report.check.outcome = .skipped(why)
            return report
        }
        if isStopRequested {
            report.check.outcome = .skipped("interrupted")
            return report
        }
        let output = scratch.appendingPathComponent("check.log")
        let check = try await CheckRunner(
            command: command, worktree: worktree, environment: environment,
            timeout: options.checkTimeout, killGrace: options.killGrace
        ).run(turn: 0, outputURL: output, log: log) { [self] in attach($0) }
        report.check = Self.step(
            command: command, result: check.result, how: Self.how(check), durationMs: check.durationMs,
            output: output, hint: "")
        return report
    }

    private static func how(_ check: CheckReport) -> String {
        check.exitCode.map { "failed (exit \($0))" } ?? check.signal.map { "failed (signal \($0))" } ?? "failed"
    }

    private static func step(
        command: String, result: CheckResult, how: String, durationMs: Int, output: URL, hint: String
    ) -> DoctorStep {
        let outcome: DoctorStep.Outcome
        switch result {
        case .passed: outcome = .passed
        case .failed: outcome = .failed(how: how)
        case .timedOut: outcome = .timedOut
        case .stopped, .interrupted: outcome = .stopped
        }
        let failed = result != .passed
        return DoctorStep(
            command: command, outcome: outcome, durationMs: durationMs,
            tail: failed ? SetupRunner.tail(of: output) : "", hint: hint)
    }
}
