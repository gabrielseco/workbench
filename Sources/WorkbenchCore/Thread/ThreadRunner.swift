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
    /// The project's check as Workbench ran it after this turn, nil when none ran.
    public var check: CheckReport?
    /// The verifier turn Workbench ran after the check (`[verifier] auto`), nil when none ran.
    public var verifier: VerifierReport?
}

public enum RunNotice: Sendable {
    case recoveredOrphanedTurn(Int)
    case recoveredOrphanedCheck(Int)
    case sweptOrphans([Int32])
    case turnStarted(turn: Int, pid: Int32?, resume: Bool)
    case claudeLine(String)
    case turnEnded(TurnReport)
    case checkStarted(turn: Int, command: String)
    case checkRan(CheckReport)
    case verifierStarted(turn: Int, skill: String)
    case verifierEnded(VerifierReport)
    case setupStarted(command: String)
    case setupRan(SetupReport)
    /// Something worth a line that is not an error: local edits left out, a base behind its origin.
    case advisory(String)
}

public struct RunOptions: Sendable {
    /// What to tell Claude after a review sent the work back. Required once a turn has succeeded.
    public var feedback: String?
    /// Replaces the goal's `turn_timeout_min`. For tests.
    public var timeoutOverride: TimeInterval?
    /// Replaces the check's timeout, which is otherwise the turn's. For tests.
    public var checkTimeoutOverride: TimeInterval?
    /// Replaces the setup command's timeout (`SetupRunner.defaultTimeout`). For tests.
    public var setupTimeoutOverride: TimeInterval?
    /// Replaces the verifier's timeout (`[verifier] timeout_min`). For tests.
    public var verifierTimeoutOverride: TimeInterval?
    public var killGrace: TimeInterval = 5
    /// Kept so scripts that pass `--allow-dirty` still work; a dirty checkout no longer blocks a run.
    public var allowDirty = false
    /// Run although a proof names a command the tool set would not let the run execute (`ProofCommands`).
    public var allowUnrunnableProofs = false
    /// The budget for this run's turns instead of the goal's. The goal file is not touched.
    public var budgetOverride: Decimal?
    /// Most a single turn may be given by `budgetOverride`.
    public static let budgetCeilingUSD: Decimal = 100
    /// The environment `claude` is derived from. Defaults to this process's.
    public var parentEnvironment: [String: String] = ProcessInfo.processInfo.environment

    /// Leave the thread's plan out of the first prompt (`run --no-plan`).
    public var noPlan = false

    public init(feedback: String? = nil) { self.feedback = feedback }
}

/// Runs turns for one thread. At most one turn at a time, by construction: the event log's exclusive lock
/// belongs to the run in progress.
public actor ThreadRunner {
    let project: Project
    let threadID: String
    let git: GitRunner
    let notify: @Sendable (RunNotice) -> Void
    var currentRun: ProcessRun?
    var stopRequested = false

    public init(
        project: Project, threadID: String, git: GitRunner,
        notify: @escaping @Sendable (RunNotice) -> Void = { _ in }
    ) {
        self.project = project
        self.threadID = threadID
        self.git = git
        self.notify = notify
    }

    /// Asks the turn or check in progress to end. It still ends with a recorded `stopped`.
    public func stop() {
        stopRequested = true
        currentRun?.stop()
    }

    // MARK: Entry point

    public func run(_ options: RunOptions = RunOptions()) async throws -> TurnReport {
        let store = ThreadStore(project: project)
        if let decision = store.state(of: threadID).decision { throw RunnerError.threadEnded(decision) }
        if let feedback = options.feedback, feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw RunnerError.emptyFeedback
        }
        if let budget = options.budgetOverride {
            guard budget > 0 else { throw RunnerError.invalidBudget("it must be more than 0") }
            guard budget <= RunOptions.budgetCeilingUSD else {
                throw RunnerError.invalidBudget("at most $\(RunOptions.budgetCeilingUSD) for one turn")
            }
        }

        let config = try Config.load(from: project.configURL)
        let goalFile = try loadGoal()
        let goal = goalFile.goal
        let skillAvailable = await verifierSkillAvailable(config: config, goal: goal)
        try Self.requireRunnable(goal: goal, config: config, options: options, verifierSkillAvailable: skillAvailable)
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
        try ThreadStore(project: project).requireNoDoctor()

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
        try await recoverOrphanedChecks(log: log)
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
            // The check's output goes in the prompt (and prompts/turn-N.md), not in the note event.
            var attachment: CheckAttachment?
            if let check = store.state(of: threadID).review.check, check.result != "passed" {
                attachment = CheckAttachment.load(
                    from: project.checkOutputURL(threadID, turn: check.turn), turn: check.turn,
                    result: check.result, exitCode: check.exitCode)
            }
            var note: [String: JSONValue] = ["text": .string(feedback)]
            if let attachment {
                note["check_turn"] = .int(attachment.turn)
                note["check_omitted_bytes"] = .int(attachment.omittedBytes)
            }
            if let budget = options.budgetOverride {
                note["budget_usd"] = .double(NSDecimalNumber(decimal: budget).doubleValue)
            }
            try await log.append(.threadNote, data: .object(note))
            prompt = PromptBuilder.followUpPrompt(
                feedback: feedback, check: attachment, granted: grantsForNextTurn(config: config))
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
            // A run killed between `worktree add` and the end of the copy left the files half there.
            if lastTurn == 0 { noteCopy(await worktreeManager.copyMissing(config.copy, into: threadID)) }
        } else {
            let local = (try? await worktreeManager.checkoutChanges()) ?? []
            let created = try await worktreeManager.create(
                threadID: threadID, base: goal.base, fetching: goal.pushTo,
                copying: config.copy)
            worktree = created.path
            baseCommit = created.baseCommit
            // Recorded before anything slow (the fetch below), so a runner killed meanwhile still has it.
            try await log.append(.worktreeCreated, data: created.eventData)
            noteCopy(created.copy)
            if !local.isEmpty {
                let one = local.count == 1
                notify(.advisory(
                    "\(local.count) file\(one ? "" : "s") changed in your checkout \(one ? "is" : "are") not part "
                        + "of this thread (it starts from \(goal.base)'s commit)"))
            }
        }

        // The approved goal beside the diff for anyone who opens the worktree; replaced every turn.
        if let goalText = try? String(contentsOf: project.goalURL(threadID), encoding: .utf8) {
            await worktreeManager.writeGoalCopy(goalText, for: threadID)
        }

        // The install step, before the first turn only (SetupRunner says when it runs).
        try await runSetupIfNeeded(
            lastTurn: lastTurn, config: config, goal: goal, worktree: worktree, log: log, options: options)

        // Said whenever the goal's prompt is built, not only when the worktree is cut: a runner killed during
        // the fetch leaves the worktree and no turn, and the retry must still look.
        if builtFromGoal {
            if let gap = await worktreeManager.baseGap(base: goal.base) {
                if let note = gap.fetchNote { notify(.advisory("\(note); comparing with what is known")) }
                if gap.behind > 0 {
                    notify(.advisory(
                        "\(goal.base) is \(gap.behind) commit\(gap.behind == 1 ? "" : "s") behind "
                            + "origin/\(goal.base); this thread is cut from your local \(goal.base)"))
                }
            }
        }

        var promptInfo: [String: JSONValue] = [:]
        if builtFromGoal {
            (prompt, promptInfo) = await firstPrompt(goal: goal, config: config, baseCommit: baseCommit, options: options)
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
                claude: claude, worktree: worktree, promptInfo: promptInfo, log: log, store: store,
                options: options)
            report = result.report
            // An unconfirmed session may not exist at all, in which case `--resume` fails at once with no
            // output. Then, and only then, try creating it.
            let canFallBack = index < attempts.count - 1
            if canFallBack, result.report.result == .failed, !result.sawOutput, !stopRequested { continue }
            report?.check = try await runCheck(
                after: result.report, config: config, goal: goal, worktree: worktree, log: log, options: options)
            let checked = report?.check
            report?.verifier = try await runVerifier(
                after: result.report, check: checked, config: config, goal: goal, worktree: worktree, log: log,
                claude: claude, options: options)
            break
        }
        // The loop above runs at least once and assigns `report` on every pass.
        // swiftlint:disable:next force_unwrapping
        return report!
    }

    var worktreeManager: WorktreeManager { WorktreeManager(repoRoot: project.root, git: git) }

    /// The commit the worktree was cut from: what `worktree.created` recorded, or for a thread that
    /// predates that event the point its branch left `base`.
    func recordedBaseCommit(goal: Goal) async -> String? {
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

    // MARK: One turn

    private struct TurnOutcome {
        var report: TurnReport
        var sawOutput: Bool
    }

    private func executeTurn(
        turn: Int, resume: Bool, sessionID: String, prompt: String, config: Config, goal: Goal, claude: URL,
        worktree: URL, promptInfo: [String: JSONValue], log: EventLogWriter, store: ThreadStore, options: RunOptions
    ) async throws -> TurnOutcome {
        let promptURL = project.promptURL(threadID, turn: turn)
        try FileManager.default.createDirectory(
            at: promptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try prompt.write(to: promptURL, atomically: true, encoding: .utf8)

        // The id was generated by this runner or read back from `session.json`, which only it writes.
        // swiftlint:disable:next force_unwrapping
        let sessionUUID = UUID(uuidString: sessionID)!
        let turnRequest = grantedTurnRequest(
            sessionID: sessionUUID, resume: resume, prompt: prompt, config: config, goal: goal, options: options)
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
            data.merge(promptInfo) { _, new in new }
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
        var code: Int32?, signal: Int32?
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
        data["denials"] = Self.deniedCalls(resultLine)
        for (key, value) in extra { data[key] = value }

        try await log.append(.turnEnded, turn: turn, data: .object(data))
        let report = TurnReport(
            turn: turn, result: result, exitCode: code, signal: signal, durationMs: duration, costUSD: cost,
            sessionID: sessionID, permissionDenials: denials, summary: resultLine?["result"] as? String)
        notify(.turnEnded(report))
        return TurnOutcome(report: report, sawOutput: sawOutput)
    }

}

extension ThreadRunner {
    // MARK: The check

    /// The project's own check, run here so that a pass is Workbench's evidence and not Claude's claim.
    /// The command is the config's; nothing in the worktree is consulted to choose it.
    private func runCheck(
        after report: TurnReport, config: Config, goal: Goal, worktree: URL, log: EventLogWriter, options: RunOptions
    ) async throws -> CheckReport? {
        guard let command = config.checkCommand, report.result != .stopped, report.result != .interrupted,
            !stopRequested
        else { return nil }
        let check = CheckRunner(
            command: command, worktree: worktree,
            environment: config.childEnvironment(from: options.parentEnvironment),
            timeout: options.checkTimeoutOverride ?? options.timeoutOverride
                ?? TimeInterval(goal.turnTimeoutMin) * 60,
            killGrace: options.killGrace)
        notify(.checkStarted(turn: report.turn, command: command))
        defer { currentRun = nil }
        let ran = try await check.run(
            turn: report.turn, outputURL: project.checkOutputURL(threadID, turn: report.turn), log: log
        ) { [self] process in await attach(process) }
        notify(.checkRan(ran))
        return ran
    }

    /// Makes the check's process the one `stop()` reaches, and stops it if that was already asked.
    func attach(_ process: ProcessRun) {
        currentRun = process
        if stopRequested { process.stop() }
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
