import Foundation

public enum RunResult: String, Sendable, Equatable {
    case succeeded
    case failed
    case stopped
    case timedOut = "timed_out"
    case budgetExceeded = "budget_exceeded"
    case interrupted
}

public struct TurnReport: Sendable, Equatable {
    public var turn: Int
    public var result: RunResult
    public var exitCode: Int32?
    public var signal: Int32?
    public var durationMs: Int
    public var costUSD: Double?
    public var sessionID: String
    public var permissionDenials: Int
    /// What Claude said last, from the `result` line.
    public var summary: String?
}

public enum RunNotice: Sendable {
    case recoveredOrphanedTurn(Int)
    case sweptOrphans([Int32])
    case turnStarted(turn: Int, pid: Int32?, resume: Bool)
    case claudeLine(String)
    case turnEnded(TurnReport)
    case checkStarted(command: String)
    case checkRan(CheckOutcome)
}

public struct RunOptions: Sendable {
    /// What to tell Claude after a review sent the work back. Required once a turn has succeeded.
    public var feedback: String?
    /// Replaces the goal's `turn_timeout_min`. For tests.
    public var timeoutOverride: TimeInterval?
    public var killGrace: TimeInterval = 5
    public var allowDirty = false
    /// The environment `claude` is derived from. Defaults to this process's.
    public var parentEnvironment: [String: String] = ProcessInfo.processInfo.environment

    public init(feedback: String? = nil) { self.feedback = feedback }
}

public enum RunnerError: Error, Equatable, Sendable, CustomStringConvertible {
    case noActiveThread
    case goalMissing(String)
    case goalInvalid(String)
    case goalNotApproved(ApprovalState)
    case feedbackRequired
    case feedbackWithoutPriorTurn
    case alreadyRunning
    case claudeNotFound(String)
    case threadEnded(String)

    public var description: String {
        switch self {
        case .noActiveThread: "there is no active thread. Start one with `workbench goal new <name>`."
        case .goalMissing(let path): "no goal at \(path)"
        case .goalInvalid(let problems): "the goal is not valid:\n\(problems)"
        case .goalNotApproved(let state):
            switch state {
            case .stale:
                "the goal changed since it was approved. Review it and run `workbench goal approve` again."
            default: "the goal is not approved. Run `workbench goal approve`."
            }
        case .feedbackRequired:
            "this thread already has a successful turn. Say what to change: `workbench run --feedback \"...\"`."
        case .feedbackWithoutPriorTurn: "there is nothing to send feedback on yet; run the goal first."
        case .alreadyRunning: "another `workbench run` holds this thread's log."
        case .claudeNotFound(let name): "cannot find `\(name)` on PATH. Set claude_path in .workbench/config.toml."
        case .threadEnded(let decision): "this thread has ended (\(decision))."
        }
    }
}

/// Runs turns for one thread. At most one turn at a time, by construction: the event log's exclusive lock
/// belongs to the run in progress.
public actor ThreadRunner {
    private let project: Project
    private let threadID: String
    private let git: GitRunner
    private let notify: @Sendable (RunNotice) -> Void
    private var currentRun: ProcessRun?
    private var currentCheck: Task<CheckOutcome, Never>?
    private var stopRequested = false

    public init(
        project: Project, threadID: String, git: GitRunner,
        notify: @escaping @Sendable (RunNotice) -> Void = { _ in }
    ) {
        self.project = project
        self.threadID = threadID
        self.git = git
        self.notify = notify
    }

    /// Asks the turn in progress to end. It still ends with a recorded `stopped`.
    public func stop() {
        stopRequested = true
        currentRun?.stop()
        currentCheck?.cancel()
    }

    // MARK: Entry point

    public func run(_ options: RunOptions = RunOptions()) async throws -> TurnReport {
        let store = ThreadStore(project: project)
        if let decision = store.state(of: threadID).decision { throw RunnerError.threadEnded(decision) }

        let config = try Config.load(from: project.configURL)
        let goalFile = try loadGoal()
        let goal = goalFile.goal
        guard goal.approval == .approved else { throw RunnerError.goalNotApproved(goal.approval) }
        guard
            let claude = ExecutableResolver.resolve(
                config.claudePath, searchPath: options.parentEnvironment["PATH"])
        else { throw RunnerError.claudeNotFound(config.claudePath) }

        let log: EventLogWriter
        do { log = try EventLogWriter.open(at: project.eventsURL(threadID)) } catch EventLogError.alreadyOpen {
            throw RunnerError.alreadyRunning
        }
        try writeRunnerInfo()
        defer {
            try? FileManager.default.removeItem(at: project.runnerURL(threadID))
        }

        do {
            let report = try await runLocked(
                log: log, store: store, config: config, goal: goal, claude: claude, options: options)
            await log.close()
            return report
        } catch {
            await log.close()
            throw error
        }
    }

    // MARK: A run, with the log held

    private func runLocked(
        log: EventLogWriter, store: ThreadStore, config: Config, goal: Goal, claude: URL, options: RunOptions
    ) async throws -> TurnReport {
        if await log.nextSeq == 1 {
            try await log.append(
                .threadCreated,
                data: [
                    "repo": .string(project.root.path), "base": .string(goal.base),
                    "worktree": .string(worktreeManager.path(for: threadID).path),
                    "branch": .string(WorktreeManager.branch(for: threadID)),
                ])
        }

        // Crash recovery: a turn left open by a runner that died ends as `interrupted`, and whatever it
        // left running in the worktree goes with it.
        if let recovered = try await log.recoverOrphanedTurn() {
            notify(.recoveredOrphanedTurn(recovered.turn))
        }
        // A check left open by a runner that died ends as `interrupted`, so none is ever stuck running.
        if let recovered = try await log.recoverOrphanedCheck() {
            notify(.checkRan(CheckOutcome.recovered(command: recovered.data["command"]?.stringValue)))
        }
        if worktreeManager.exists(threadID) {
            let swept = OrphanSweeper.sweep(inside: worktreeManager.path(for: threadID))
            if !swept.isEmpty {
                try await log.append(.init(rawValue: "orphans.swept"), data: ["pids": .array(swept.map { .int(Int($0)) })])
                notify(.sweptOrphans(swept))
            }
        }

        // What to say this turn.
        let anySuccess = await anyTurnSucceeded()
        let lastTurn = await log.lastTurn
        var prompt = ""
        var builtFromGoal = false
        if let feedback = options.feedback {
            guard lastTurn > 0 else { throw RunnerError.feedbackWithoutPriorTurn }
            try await log.append(.threadNote, data: ["text": .string(feedback)])
            prompt = PromptBuilder.followUpPrompt(feedback: feedback)
        } else {
            if anySuccess { throw RunnerError.feedbackRequired }
            builtFromGoal = true
        }

        // The worktree.
        var worktree: URL
        var baseCommit: String?
        if worktreeManager.exists(threadID) {
            worktree = worktreeManager.path(for: threadID)
            baseCommit = await recordedBaseCommit(goal: goal)
        } else {
            let created = try await worktreeManager.create(
                threadID: threadID, base: goal.base, allowDirty: options.allowDirty)
            worktree = created.path
            baseCommit = created.baseCommit
            try await log.append(
                .worktreeCreated,
                data: [
                    "path": .string(created.path.path), "branch": .string(created.branch),
                    "base_commit": .string(created.baseCommit),
                ])
        }

        // The prompt built from the goal carries the project's instructions as they were at the base
        // commit: not the main checkout, and not the worktree, which the run may already have edited.
        var instructions: JSONValue?
        if builtFromGoal {
            var loaded: ProjectInstructions?
            if config.projectInstructions, let baseCommit {
                loaded = await ProjectInstructions.load(git: git, repo: project.root, commit: baseCommit)
            }
            prompt = PromptBuilder.firstPrompt(
                goal: goal, checkCommand: config.checkCommand, instructions: loaded)
            instructions = loaded?.eventData ?? .null
        }

        // The session: decided before spawning and written down first (spike S4).
        let sessionID: String
        var attempts: [Bool]  // resume flags to try, in order
        if let existing = store.session(of: threadID) {
            sessionID = existing.sessionID
            attempts = existing.confirmed ? [true] : [true, false]
        } else {
            sessionID = UUID().uuidString.lowercased()
            attempts = [false]
            try store.save(.init(sessionID: sessionID, confirmed: false), for: threadID)
        }

        var report: TurnReport?
        for (index, resume) in attempts.enumerated() {
            let turn = await log.lastTurn + 1
            let result = try await executeTurn(
                turn: turn, resume: resume, sessionID: sessionID, prompt: prompt, config: config, goal: goal,
                claude: claude, worktree: worktree, instructions: instructions, log: log, store: store,
                options: options)
            report = result.report
            // An unconfirmed session may not exist at all, in which case `--resume` fails at once with no
            // output. Then, and only then, try creating it.
            let canFallBack = index < attempts.count - 1
            if canFallBack, result.report.result == .failed, !result.sawOutput, !stopRequested { continue }
            break
        }
        // The loop above runs at least once and assigns `report` on every pass.
        // The check is evidence from Workbench, not Claude's say-so. A turn the user stopped, or that was
        // cut short by a dead runner, is not checked.
        // swiftlint:disable:next force_unwrapping
        let finished = report!
        if let command = config.checkCommand, finished.result != .stopped, finished.result != .interrupted {
            try await runCheck(
                command: command, turn: finished.turn, worktree: worktree, goal: goal, config: config,
                log: log, options: options)
        }
        return finished
    }

    private var worktreeManager: WorktreeManager { WorktreeManager(repoRoot: project.root, git: git) }

    // MARK: One turn

    private struct TurnOutcome {
        var report: TurnReport
        var sawOutput: Bool
    }

    private func executeTurn(
        turn: Int, resume: Bool, sessionID: String, prompt: String, config: Config, goal: Goal, claude: URL,
        worktree: URL, instructions: JSONValue?, log: EventLogWriter, store: ThreadStore, options: RunOptions
    ) async throws -> TurnOutcome {
        let promptURL = project.promptURL(threadID, turn: turn)
        try FileManager.default.createDirectory(
            at: promptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try prompt.write(to: promptURL, atomically: true, encoding: .utf8)

        // The id was generated by this runner or read back from `session.json`, which only it writes.
        // swiftlint:disable:next force_unwrapping
        let sessionUUID = UUID(uuidString: sessionID)!
        let turnRequest = TurnRequest(
            sessionID: sessionUUID, resume: resume, budgetUSD: goal.budgetUSD, prompt: prompt,
            appendSystemPrompt: PromptBuilder.rules(checkCommand: config.checkCommand))
        let invocation = try config.invocation(for: turnRequest)

        // The prompt and system prompt are in prompts/turn-N.md and the config, not in the log.
        var shownArgs = invocation.arguments
        if let dashes = shownArgs.firstIndex(of: "--") { shownArgs = Array(shownArgs[..<dashes]) }
        if let i = shownArgs.firstIndex(of: "--append-system-prompt"), i + 1 < shownArgs.count {
            shownArgs[i + 1] = "<rules>"
        }
        let startedData: (Int32?) -> JSONValue = { pid in
            var data: [String: JSONValue] = [
                "session_id": .string(sessionID), "resume": .bool(resume),
                "pid": pid.map { .int(Int($0)) } ?? .null,
                "argv": .array(([claude.path] + shownArgs).map { .string($0) }),
                "prompt_ref": .string("prompts/turn-\(turn).md"),
            ]
            if let instructions { data["instructions"] = instructions }
            return .object(data)
        }

        var spawn = SpawnRequest(
            executable: claude, arguments: invocation.arguments,
            environment: config.childEnvironment(from: options.parentEnvironment), workingDirectory: worktree,
            timeout: options.timeoutOverride ?? TimeInterval(goal.turnTimeoutMin) * 60)
        spawn.killGrace = options.killGrace

        // From here on the turn is recorded, whatever happens.
        let process: ProcessRun
        if stopRequested {
            try await log.append(.turnStarted, turn: turn, data: startedData(nil))
            return try await endTurn(
                log: log, turn: turn, sessionID: sessionID, result: .stopped, started: Date(),
                extra: ["error": "stopped before the process started"])
        }
        do {
            process = try ProcessRunner.start(spawn)
        } catch {
            try await log.append(.turnStarted, turn: turn, data: startedData(nil))
            return try await endTurn(
                log: log, turn: turn, sessionID: sessionID, result: .failed, started: Date(),
                extra: ["error": .string("could not start claude: \(error)")])
        }
        currentRun = process
        defer { currentRun = nil }
        if stopRequested { process.stop() }

        let startedAt = Date()
        try await log.append(.turnStarted, turn: turn, data: startedData(process.pid))
        notify(.turnStarted(turn: turn, pid: process.pid, resume: resume))

        var resultLine: [String: Any]?
        var sawOutput = false
        var confirmed = false
        var exit: ProcessExit?
        var recordingFailure: Error?

        // One iterator for the whole stream. If the log cannot be written the child is stopped, but the
        // stream is still drained to its `exited` event so the end of the turn can be recorded truthfully.
        var iterator = process.events.makeAsyncIterator()
        while let event = await iterator.next() {
            if case .exited(let e) = event { exit = e; continue }
            if recordingFailure != nil { continue }
            do {
                switch event {
                case .started, .exited:
                    break
                case .line(let line):
                    sawOutput = true
                    try await log.appendClaudeLine(line, turn: turn)
                    notify(.claudeLine(line))
                    if !confirmed, line.contains("\"session_id\":\"\(sessionID)\"") {
                        confirmed = true
                        try store.save(.init(sessionID: sessionID, confirmed: true), for: threadID)
                    }
                    if line.contains("\"type\":\"result\""), let parsed = Self.object(line) {
                        resultLine = parsed
                    }
                case .oversizedLine(let preview, let total):
                    sawOutput = true
                    try await log.appendOversizedClaudeLine(preview: preview, totalBytes: total, turn: turn)
                }
            } catch {
                recordingFailure = error
                process.stop()
            }
        }

        if let failure = recordingFailure {
            return try await endTurn(
                log: log, turn: turn, sessionID: sessionID, result: .failed, started: startedAt,
                extra: ["error": .string("recording failed: \(failure)")], exit: exit,
                resultLine: resultLine, sawOutput: sawOutput)
        }

        // Past the output limit the result line may have been dropped from the stream; it is kept aside.
        if resultLine == nil, let last = exit?.lastLineAfterLimit {
            try await log.appendClaudeLine(last, turn: turn)
            if let parsed = Self.object(last), parsed["type"] as? String == "result" { resultLine = parsed }
        }

        let outcome = Self.classify(exit: exit, result: resultLine)
        return try await endTurn(
            log: log, turn: turn, sessionID: sessionID, result: outcome, started: startedAt, exit: exit,
            resultLine: resultLine, sawOutput: sawOutput)
    }

    private func endTurn(
        log: EventLogWriter, turn: Int, sessionID: String, result: RunResult, started: Date,
        extra: [String: JSONValue] = [:], exit: ProcessExit? = nil, resultLine: [String: Any]? = nil,
        sawOutput: Bool = false
    ) async throws -> TurnOutcome {
        var code: Int32?
        var signal: Int32?
        switch exit?.termination {
        case .exited(let c)?: code = c
        case .signaled(let s)?: signal = s
        case .lost?, nil: break
        }
        let cost = (resultLine?["total_cost_usd"] as? NSNumber)?.doubleValue
        let denials = (resultLine?["permission_denials"] as? [Any])?.count ?? 0
        let duration = exit?.durationMs ?? Int(Date().timeIntervalSince(started) * 1000)

        var data: [String: JSONValue] = [
            "result": .string(result.rawValue),
            "exit_code": code.map { .int(Int($0)) } ?? .null,
            "signal": signal.map { .int(Int($0)) } ?? .null,
            "duration_ms": .int(duration),
            "session_id": .string(sessionID),
            "permission_denials": .int(denials),
        ]
        if let cost { data["cost_usd"] = .double(cost) }
        if let exit {
            data["cause"] = .string(String(describing: exit.cause))
            if exit.escalatedToKill { data["escalated_to_kill"] = true }
            if exit.sweptProcesses > 0 { data["swept_processes"] = .int(exit.sweptProcesses) }
            if exit.outputTruncated { data["output_truncated"] = true }
            if exit.drainTimedOut { data["drain_timed_out"] = true }
            if exit.termination == .lost { data["lost"] = true }
            let tail = exit.stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
            if !tail.isEmpty { data["stderr_tail"] = .string(String(tail.suffix(2000))) }
        }
        for (key, value) in extra { data[key] = value }

        try await log.append(.turnEnded, turn: turn, data: .object(data))
        let report = TurnReport(
            turn: turn, result: result, exitCode: code, signal: signal, durationMs: duration, costUSD: cost,
            sessionID: sessionID, permissionDenials: denials, summary: resultLine?["result"] as? String)
        notify(.turnEnded(report))
        return TurnOutcome(report: report, sawOutput: sawOutput)
    }

    // MARK: Classification (pure, tested directly)

    static func classify(exit: ProcessExit?, result: [String: Any]?) -> RunResult {
        guard let exit else { return .failed }
        switch exit.cause {
        case .stopped: return .stopped
        case .timedOut: return .timedOut
        case .natural: break
        }
        if case .signaled = exit.termination { return .failed }
        guard let result else { return .failed }

        let subtype = result["subtype"] as? String
        let terminal = result["terminal_reason"] as? String
        if subtype == "error_max_budget_usd" || terminal == "budget_exhausted" { return .budgetExceeded }
        // A success line from a process that then exited non-zero is not a success.
        if case .exited(let code) = exit.termination, code != 0 { return .failed }
        if subtype == "success", result["is_error"] as? Bool != true { return .succeeded }
        return .failed
    }

    // MARK: Helpers

    private func loadGoal() throws -> GoalFile {
        let url = project.goalURL(threadID)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw RunnerError.goalMissing(url.path)
        }
        do { return try GoalFile.parse(text) } catch let error as GoalParseError {
            throw RunnerError.goalInvalid(error.description)
        }
    }

    private func anyTurnSucceeded() async -> Bool {
        guard let contents = try? EventLogReader.read(at: project.eventsURL(threadID)) else { return false }
        return contents.events.contains {
            $0.kind == .turnEnded && $0.data["result"]?.stringValue == RunResult.succeeded.rawValue
        }
    }

    private func writeRunnerInfo() throws {
        let member = ProcessTree.member(for: getpid())
        let info: [String: Any] = [
            "pid": getpid(), "started_seconds": member?.startSeconds ?? 0,
            "started_micros": member?.startMicros ?? 0,
        ]
        let data = try JSONSerialization.data(withJSONObject: info, options: [.sortedKeys])
        try data.write(to: project.runnerURL(threadID), options: .atomic)
    }

    private static func object(_ line: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
    }
}

extension ThreadRunner {
    private func runCheck(
        command: String, turn: Int, worktree: URL, goal: Goal, config: Config, log: EventLogWriter,
        options: RunOptions
    ) async throws {
        try await log.append(.checkStarted, turn: turn, data: ["command": .string(command)])
        notify(.checkStarted(command: command))
        let task = Task { [project, threadID] in
            await CheckRunner.run(
                command: command, worktree: worktree,
                environment: config.childEnvironment(from: options.parentEnvironment),
                timeout: options.timeoutOverride ?? TimeInterval(goal.turnTimeoutMin) * 60,
                killGrace: options.killGrace, logURL: project.checkLogURL(threadID, turn: turn),
                outputRef: "checks/turn-\(turn).log")
        }
        currentCheck = task
        if stopRequested { task.cancel() }
        let outcome = await task.value
        currentCheck = nil
        try await log.append(.checkRan, turn: turn, data: outcome.eventData)
        notify(.checkRan(outcome))
    }

    /// The commit the worktree was cut from: what `worktree.created` recorded, or for a thread that
    /// predates that event the point its branch left `base`.
    private func recordedBaseCommit(goal: Goal) async -> String? {
        if let contents = try? EventLogReader.read(at: project.eventsURL(threadID)),
            let event = contents.events.last(where: { $0.kind == .worktreeCreated }),
            let sha = event.data["base_commit"]?.stringValue {
            return sha
        }
        let result = try? await git.run(
            ["merge-base", WorktreeManager.branch(for: threadID), goal.base], in: project.root)
        guard let result, result.succeeded else { return nil }
        let sha = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return sha.isEmpty ? nil : sha
    }
}
