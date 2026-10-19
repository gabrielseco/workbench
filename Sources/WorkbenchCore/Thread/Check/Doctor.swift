import CoreGraphics
import Foundation

public enum DoctorError: Error, Equatable, CustomStringConvertible {
    case noConfig(String)
    case runnerLive(String)
    case invalidBase(String)
    case alreadyRunning

    public var description: String {
        switch self {
        case .alreadyRunning: "another `workbench doctor` is running in this project"
        case .noConfig(let path): "no config at \(path): run `workbench init` first"
        case .runnerLive(let id):
            "a turn or check of thread \(id) is running; doctor would run a second check next to it. Wait, or `workbench stop`"
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
        // A child spawned elsewhere in this process shares the descriptor between fork and exec, and the lock
        // lives on the open file, so a short wait absorbs that moment (as the event log's lock does).
        let deadline = Date().addingTimeInterval(1)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR, Date() < deadline else {
                close(fd)
                throw DoctorError.alreadyRunning
            }
            usleep(2_000)
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

/// `[verifier]` as doctor found it: the config, and the skill as it is at the base commit.
public struct DoctorVerifier: Sendable, Equatable {
    public var config: VerifierConfig
    /// `--model` the verifier gets: its own, else the coding model, else nil for the CLI's default.
    public var model: String?
    public var skill: VerifierSkill?
    /// Why the skill cannot be used, when it cannot. A warning: doctor still runs the declared steps.
    public var problem: String?
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
    public var verify: DoctorStep
    /// What the verify step left in its proof directory.
    public var verifyFiles: [ProofFile] = []
    /// Something worth knowing about a verify that passed (it wrote no files).
    public var verifyWarning: String?
    public var appType: AppType = .web
    /// Nil when the config has no `[verifier]`.
    public var verifier: DoctorVerifier?
    /// What is odd about the review stages (`review.stages`, `[review.stage.<name>]`). Warnings: they never fail doctor.
    public var reviewWarnings: [String] = []
    /// Set when the throwaway worktree could not be removed, with what to run by hand.
    public var cleanupProblem: String?

    /// Everything declared passed and nothing was left behind. A step the config does not declare is not a
    /// failure.
    public var passed: Bool {
        cleanupProblem == nil
            && [setup, check, verify].allSatisfy {
            switch $0.outcome {
                case .passed, .notDeclared: true
                default: false
                }
            }
    }

    /// A step ended by a stop, or was skipped because one arrived between steps.
    public var wasStopped: Bool {
        [setup, check, verify].contains {
            switch $0.outcome {
            case .stopped, .skipped("interrupted"): true
            default: false
            }
        }
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
        /// Nil takes the config's `verify_timeout_min`.
        public var verifyTimeout: TimeInterval?
        public var killGrace: TimeInterval = 5
        /// Whether the process running doctor may record the screen. Replaced in tests.
        public var screenRecordingGranted: @Sendable () -> Bool = { CGPreflightScreenCaptureAccess() }
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
            check: DoctorStep(command: config.checkCommand, outcome: .notDeclared, tail: "", hint: ""),
            verify: DoctorStep(command: config.verifyCommand, outcome: .notDeclared, tail: "", hint: ""),
            appType: config.appType)
        if let verifier = config.verifier {
            report.verifier = await readVerifier(verifier, model: config.verifierModel, base: base)
        }
        report.reviewWarnings = Self.reviewWarnings(
            config.review, root: project.root, hasVerifyCommand: config.verifyCommand != nil)
        guard config.setupCommand != nil || config.checkCommand != nil || config.verifyCommand != nil else {
            return report
        }

        // One doctor at a time: a second would otherwise remove the first one's live worktree as a "leftover".
        let lock = try ProjectLock.acquire(project)
        defer { ProjectLock.release(lock) }
        // After the lock: a run that starts now sees the lock and refuses itself (it writes runner.json first).
        if let live = store.threadWithLiveRunner() { throw DoctorError.runnerLive(live) }
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

    /// The skill at the base commit, never the working tree, which a run may have edited.
    private func readVerifier(_ verifier: VerifierConfig, model: String?, base: String) async -> DoctorVerifier {
        var found = DoctorVerifier(config: verifier, model: model)
        switch await VerifierSkill.load(git: git, repo: project.root, commit: base, path: verifier.skill) {
        case .success(let skill): found.skill = skill
        case .failure(let problem): found.problem = problem.description
        }
        return found
    }

    /// The review stages as declared: a list without `pr-review`, a rubric file that is not in the checkout, a stage
    /// that reads proof with no verify step to leave any, a table no list names. The project knows its own pipeline,
    /// so each is said and none is refused.
    static func reviewWarnings(_ review: ReviewConfig, root: URL, hasVerifyCommand: Bool) -> [String] {
        var warnings: [String] = []
        if !review.stages.contains(ReviewConfig.prReviewStage) {
            warnings.append(
                "review.stages does not list \(ReviewConfig.prReviewStage): no correctness review will run in the loop")
        }
        for name in review.stages {
            if review.stage(name)?.needsProof == true, !hasVerifyCommand {
                warnings.append(
                    "the \(name) stage reads proof, and there is no verify_command to leave any: its rounds will fail")
            }
            guard let stage = review.stage(name), let rubric = stage.rubric else { continue }
            let key = stage.skill != nil ? "skill" : "prompt"
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(
                atPath: root.appendingPathComponent(rubric).path, isDirectory: &isDirectory)
            if !exists || isDirectory.boolValue {
                warnings.append("the \(name) stage's \(key) \(rubric) is not a file in this checkout")
            }
        }
        for name in review.unlistedTables {
            warnings.append("[review.stage.\(name)] is not listed in review.stages, so it is ignored")
        }
        return warnings
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

        if let command = config.checkCommand {
            if let why = skipReason("setup", report.setup) {
                report.check.outcome = .skipped(why)
            } else {
                let output = scratch.appendingPathComponent("check.log")
                let check = try await CheckRunner(
                    command: command, worktree: worktree, environment: environment,
                    timeout: options.checkTimeout, killGrace: options.killGrace
                ).run(turn: 0, outputURL: output, log: log) { [self] in attach($0) }
                report.check = Self.step(
                    command: command, result: check.result, how: Self.how(check), durationMs: check.durationMs,
                    output: output, hint: "")
            }
        }

        guard let command = config.verifyCommand else { return report }
        if let why = skipReason("setup", report.setup) ?? skipReason("check", report.check) {
            report.verify.outcome = .skipped(why)
            return report
        }
        if config.appType == .desktop, !options.screenRecordingGranted() {
            let app = options.environment["TERM_PROGRAM"] ?? "the app that runs workbench (your terminal)"
            report.verify.outcome = .failed(how: "not run: Screen Recording is not granted to \(app)")
            report.verify.hint =
                "Grant it in System Settings > Privacy & Security > Screen & System Audio Recording, then restart "
                + "the app. `app_type = \"desktop\"` in the config makes doctor check this."
            return report
        }
        return try await runVerify(report, command: command, config: config, worktree: worktree, scratch: scratch,
            environment: environment, options: options, log: log)
    }

    /// Why an earlier step stops the next one, or nil when it may go on.
    private func skipReason(_ name: String, _ step: DoctorStep) -> String? {
        if isStopRequested { return "interrupted" }
        switch step.outcome {
        case .passed, .notDeclared: return nil
        default: return "\(name) did not pass"
        }
    }

    private func runVerify(
        _ initial: DoctorReport, command: String, config: Config, worktree: URL, scratch: URL,
        environment: [String: String], options: Options, log: EventLogWriter
    ) async throws -> DoctorReport {
        var report = initial
        // A stub for WORKBENCH_GOAL, so a verify that reads which pages to capture has a file to open.
        let goal = scratch.appendingPathComponent("goal.md")
        try Data("# doctor\n\nA throwaway goal: doctor has no task.\n".utf8).write(to: goal)
        let output = scratch.appendingPathComponent("verify.log")
        let proof = scratch.appendingPathComponent("proof")
        let ran = try await VerifyRunner(
            command: command, worktree: worktree, environment: environment,
            timeout: options.verifyTimeout ?? TimeInterval(config.verifyTimeoutMin) * 60, killGrace: options.killGrace,
            threadID: Self.worktreeID, goalPath: goal.path
        ).run(turn: 0, proofDirectory: proof, threadDirectory: scratch, outputURL: output, log: log) { [self] in
            attach($0)
        }
        let how = ran.exitCode.map { "failed (exit \($0))" } ?? ran.signal.map { "failed (signal \($0))" } ?? "failed"
        report.verify = Self.step(
            command: command, result: ran.result, how: how, durationMs: ran.durationMs, output: output, hint: "")
        report.verifyFiles = ran.proof
        if ran.result == .passed, ran.proof.isEmpty {
            report.verifyWarning = "wrote no files to WORKBENCH_PROOF_DIR: nothing would be shown as proof"
        }
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
