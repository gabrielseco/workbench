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
    case activity(String)
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
    /// The coding turn in progress; `stop()` reaches it the way it reaches `currentRun`.
    var currentExecution: AgentExecution?
    var stopRequested = false
    /// The provider of the coding turn in progress, set when the turn starts: what its record has and has not got.
    var codingProvider: AgentProviderID = .claude

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
        currentExecution?.stop()
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
        if options.budgetOverride != nil, goal.isTimeoutOnly {
            throw RunnerError.invalidBudget(
                "this goal has no dollar cap (spend_policy: timeout_only), so there is no budget to override")
        }
        let skillAvailable = await verifierSkillAvailable(config: config, goal: goal)
        try Self.requireRunnable(goal: goal, config: config, options: options, verifierSkillAvailable: skillAvailable)
        let agent = config.resolvedRunAgent(goalModel: goal.model)
        // What this provider cannot do comes before the approval check: it is what has to change, and approving again
        // before changing it would only meet it next.
        try Self.requireProviderCanCode(agent: agent, goal: goal, options: options)
        try requireReadAlso(config, goal: goal)
        try Self.requireApprovedAgent(
            state: store.state(of: threadID), agent: agent, spendPolicy: goal.spendPolicyName)
        let name = config.executable(for: agent.provider)
        guard let executable = ExecutableResolver.resolve(name, searchPath: options.parentEnvironment["PATH"]) else {
            throw agent.provider == .claude
                ? RunnerError.claudeNotFound(name) : RunnerError.agentNotFound(provider: "\(agent.provider)", name: name)
        }

        let log = try openLog()
        try writeRunnerInfo()
        defer {
            try? FileManager.default.removeItem(at: project.runnerURL(threadID))
        }
        try ThreadStore(project: project).requireNoDoctor()

        do {
            let report = try await runLocked(
                log: log, store: store, config: config, goal: goal, executable: executable, options: options)
            await log.close()
            return report
        } catch {
            await log.close()
            throw error
        }
    }

    // MARK: A run, with the log held

    private func runLocked(
        log: EventLogWriter, store: ThreadStore, config: Config, goal: Goal, executable: URL, options: RunOptions
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
        var codexFollowUp: (feedback: String?, check: CheckAttachment?)?
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
            if config.resolvedRunAgent(goalModel: goal.model).provider == .claude {
                prompt = PromptBuilder.followUpPrompt(
                    feedback: feedback, check: attachment, granted: grantsForNextTurn(config: config))
            } else {
                // A fresh process remembers nothing: its prompt needs the worktree, so it is built below.
                codexFollowUp = (feedback, attachment)
            }
        } else {
            if anySuccess { throw RunnerError.feedbackRequired }
            builtFromGoal = true
            codexFollowUp = codexRerun(store: store, lastTurn: lastTurn, config: config, goal: goal)
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
        let screenshots = await copyGoalIntoWorktree()

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
        let runAgent = config.resolvedRunAgent(goalModel: goal.model)
        if builtFromGoal || codexFollowUp != nil {
            (prompt, promptInfo) = try await firstPrompt(
                goal: goal, config: config, baseCommit: baseCommit, options: options, screenshots: screenshots)
        }
        if runAgent.provider == .codex {
            (prompt, promptInfo) = await codexPrompt(
                first: prompt, info: promptInfo, followUp: codexFollowUp, worktree: worktree,
                base: baseCommit ?? goal.base, config: config)
        }

        // The session: decided before spawning and written down first (spike S4).
        let sessionID: String
        var attempts: [Bool]  // resume flags to try, in order
        if runAgent.provider != .claude {
            // No native resume: every turn is a fresh process, so there is no session to keep or to confirm.
            sessionID = ""
            attempts = [false]
        } else if let existing = Self.resumableSession(store: store, threadID: threadID, provider: runAgent.provider) {
            sessionID = existing.sessionID
            attempts = existing.confirmed ? [true] : [true, false]
        } else {
            sessionID = UUID().uuidString.lowercased()
            attempts = [false]
            try store.save(
                .init(sessionID: sessionID, confirmed: false, provider: "\(runAgent.provider)"), for: threadID)
        }

        var report: TurnReport?
        for (index, resume) in attempts.enumerated() {
            let turn = await log.lastTurn + 1
            let result = try await executeTurn(
                turn: turn, resume: resume, sessionID: sessionID, prompt: prompt, config: config, goal: goal,
                executable: executable, worktree: worktree, promptInfo: promptInfo, log: log, store: store,
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
                claude: verifierClaude(config: config, executable: executable, options: options), options: options)
            break
        }
        // The loop above runs at least once and assigns `report` on every pass.
        // swiftlint:disable:next force_unwrapping
        return report!
    }

    var worktreeManager: WorktreeManager { WorktreeManager(repoRoot: project.root, git: git) }

    // MARK: One turn

    private struct TurnOutcome {
        var report: TurnReport
        var sawOutput: Bool
    }

    private func executeTurn(
        turn: Int, resume: Bool, sessionID: String, prompt: String, config: Config, goal: Goal, executable: URL,
        worktree: URL, promptInfo: [String: JSONValue], log: EventLogWriter, store: ThreadStore, options: RunOptions
    ) async throws -> TurnOutcome {
        let promptURL = project.promptURL(threadID, turn: turn)
        try FileManager.default.createDirectory(
            at: promptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try prompt.write(to: promptURL, atomically: true, encoding: .utf8)

        let agent = config.resolvedRunAgent(goalModel: goal.model)
        codingProvider = agent.provider
        let provider: any AgentProvider =
            agent.provider == .codex ? CodexProvider(executable: config.executable(for: .codex)) : ClaudeProvider(config: config)
        let request = try grantedAgentRequest(
            sessionID: sessionID, resume: resume, prompt: prompt, config: config, goal: goal, worktree: worktree,
            outputDirectory: promptURL.deletingLastPathComponent(), options: options)
        if let refusal = request.validate(against: provider) { throw refusal }
        let invocation = try provider.invocation(for: request)

        // The prompt and system prompt are in prompts/turn-N.md and the config, not in the log.
        let attempts = AttemptLog(log: log, role: "run", turn: turn, agent: agent)
        let startedData: (Int32?) -> JSONValue = { pid in
            var data: [String: JSONValue] = [
                "resume": .bool(resume),
                "pid": pid.map { .int(Int($0)) } ?? .null,
                "argv": .array(([executable.path] + invocation.displayArguments).map { .string($0) }),
                "prompt_ref": .string("prompts/turn-\(turn).md"),
            ]
            // A Codex turn has no session to name: it is one fresh process, and cannot be resumed.
            if agent.provider == .claude { data["session_id"] = .string(sessionID) }
            data.merge(promptInfo) { _, new in new }
            return .object(ThreadService.agentFields(agent, data))
        }
        // `turn.started` and the attempt of the process it starts, in that order; the attempt ends before `turn.ended`.
        let begin: (Int32?) async throws -> String = { pid in
            try await log.append(.turnStarted, turn: turn, data: startedData(pid))
            return try await attempts.start()
        }

        // From here on the turn is recorded, whatever happens.
        if stopRequested {
            let attempt = try await begin(nil)
            return try await endTurn(
                log: log, turn: turn, sessionID: sessionID, result: .stopped, started: Date(), attempt: attempt,
                extra: ["error": "stopped before the process started"])
        }
        // The recorder writes every line to the log as it comes, verbatim and in order; `held` keeps the first one
        // behind `turn.started`, which carries the pid.
        let transcript = TranscriptWriter(url: TranscriptFile.url(in: project.threadDirectory(threadID), turn: turn))
        defer { transcript.close() }
        let recorder = TurnRecorder(
            log: log, transcript: transcript, turn: turn, sessionID: sessionID, provider: "\(agent.provider)",
            threadID: threadID, store: store,
            notify: notify, keepsSession: agent.provider == .claude)
        let execution: AgentExecution
        do {
            execution = try AgentRunner.start(provider: provider, request: request, recorder: recorder, held: true)
        } catch let failure as AgentFailure {
            let attempt = try await begin(nil)
            return try await endTurn(
                log: log, turn: turn, sessionID: sessionID, result: .failed, started: Date(), attempt: attempt,
                extra: ["error": .string("could not start \(agent.provider): \(failure.diagnostic ?? failure.message)")])
        }
        currentExecution = execution
        defer { currentExecution = nil }
        if stopRequested { execution.stop() }

        let startedAt = Date()
        let attempt: String
        do {
            attempt = try await begin(execution.pid)
        } catch {
            execution.stop()
            _ = await execution.completion
            throw error
        }
        notify(.turnStarted(turn: turn, pid: execution.pid, resume: resume))
        execution.begin()
        let completion = await execution.completion
        try await recorder.flush()

        if let failure = completion.recordingFailure {
            return try await endTurn(
                log: log, turn: turn, sessionID: sessionID, result: .failed, started: startedAt, attempt: attempt,
                extra: ["error": .string("recording failed: \(failure)")], completion: completion,
                sawOutput: recorder.sawOutput, transcript: transcript.summary)
        }
        let outcome = Self.runResult(
            exit: completion.process, outcome: completion.provider, failure: completion.failure)
        return try await endTurn(
            log: log, turn: turn, sessionID: sessionID, result: outcome, started: startedAt, attempt: attempt,
            completion: completion, sawOutput: recorder.sawOutput, transcript: transcript.summary)
    }

    private func endTurn(
        log: EventLogWriter, turn: Int, sessionID: String, result: RunResult, started: Date, attempt: String,
        extra: [String: JSONValue] = [:], completion: AgentCompletion? = nil, sawOutput: Bool = false,
        transcript: TranscriptSummary? = nil
    ) async throws -> TurnOutcome {
        let exit = completion?.process
        var code: Int32?, signal: Int32?
        switch exit?.termination {
        case .exited(let c)?: code = c
        case .signaled(let s)?: signal = s
        case .lost?, nil: break
        }
        let cost = completion?.usage?.costUSD
        let denials = completion?.permissionDenialCount ?? 0
        let duration = exit?.durationMs ?? Int(Date().timeIntervalSince(started) * 1000)

        var data: [String: JSONValue] = [
            "result": .string(result.rawValue),
            "exit_code": code.map { .int(Int($0)) } ?? .null,
            "signal": signal.map { .int(Int($0)) } ?? .null,
            "duration_ms": .int(duration),
        ]
        data.merge(providerFields(sessionID: sessionID, denials: denials, summary: completion?.summary)) { _, new in new }
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
        data["denials"] = Self.deniedCalls(completion?.permissionDenials ?? [])
        if let transcript { data["transcript"] = transcript.json }
        for (key, value) in extra { data[key] = value }

        try await AttemptLog.close(log, attempt, result.rawValue)
        try await log.append(.turnEnded, turn: turn, data: .object(data))
        // The turn is over, so nobody appends to its transcript again: gzip it. A failure leaves it plain.
        TranscriptFile.compress(TranscriptFile.url(in: project.threadDirectory(threadID), turn: turn))
        let report = TurnReport(
            turn: turn, result: result, exitCode: code, signal: signal, durationMs: duration, costUSD: cost,
            sessionID: sessionID, permissionDenials: denials, summary: completion?.summary)
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

extension ThreadRunner {
    /// Says so when the copy was not written, so a person who opens the worktree and finds no goal knows why. Returns the
    /// names of the goal's screenshots that are now in the worktree, for the prompt to point at.
    fileprivate func copyGoalIntoWorktree() async -> [String] {
        guard let text = try? String(contentsOf: project.goalURL(threadID), encoding: .utf8) else { return [] }
        if case .skipped(let why) = await worktreeManager.writeGoalCopy(text, for: threadID) {
            notify(.advisory("the goal was not copied into the worktree: \(why)"))
        }
        let kept = GoalAttachments.stored(in: project.threadDirectory(threadID))
        let names = await worktreeManager.writeAttachmentCopies(kept, for: threadID)
        if names.count < kept.count { notify(.advisory("the goal's screenshots were not copied into the worktree")) }
        return names
    }
}
