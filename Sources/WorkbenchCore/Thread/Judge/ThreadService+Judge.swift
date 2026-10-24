import Foundation

/// What `workbench judge` came to. A failed judge is a result, not a thrown error: it is advisory, so a missing
/// `claude`, a timeout, a budget stop or an unusable answer only mean there is no verdict this time.
public struct JudgeResult: Sendable, Equatable {
    public var turn: Int
    public var verdict: JudgeVerdict?
    public var costUSD: Double?
    /// Why there is no verdict.
    public var failure: String?
}

public enum JudgeRefusal: Error, Equatable, Sendable, CustomStringConvertible {
    case noTurn
    case alreadyJudged(turn: Int)
    case goalUnreadable(String)
    case invalidModel(String)
    case busy

    public var description: String {
        switch self {
        case .noTurn: "nothing to judge: no turn has run."
        case .alreadyJudged(let turn):
            "turn \(turn) was judged already (`workbench review` shows it). Pass --again to ask once more."
        case .goalUnreadable(let why): "the goal could not be read: \(why)"
        case .invalidModel: "--model needs a model name or alias like \"haiku\""
        case .busy: "another command is using this thread (a run, a send-back or another judge); try again when it ends."
        }
    }
}

extension ThreadService {
    /// Most screenshots the judge is shown, and the largest it is shown.
    static let judgeScreenshotLimit = 8
    static let judgeScreenshotBytes = 5 << 20
    static let judgeUntrackedLimit = 20

    /// Runs the advisory judge on the latest turn and records `judge.ran`, with the verdict or the reason there
    /// is none. Read-only and separate from the work: its own session and budget, no numbered turn, tools
    /// limited to `Read` on the screenshots (or none), and nothing in Workbench acts on what it says.
    ///
    /// The thread's log is held from the once-per-turn check to the record, so two judges, or a judge and a
    /// run, cannot both spend money on the same turn: the second is refused as `busy`. It sees what `review`
    /// shows: the work in the worktree against where it left the base (committed or not; untracked files are
    /// named), the check, the verify step and the screenshots the verify step left.
    ///
    /// - Parameter attach: called with the running judge, so the caller can stop it (Ctrl-C).
    public func judge(
        id: String, config: Config, again: Bool = false, budget: Decimal = Judge.budgetUSD, model: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment, timeout: TimeInterval = Judge.timeout,
        attach: @Sendable (AgentExecution) -> Void = { _ in }
    ) async throws -> JudgeResult {
        if let model, !SafeNames.isModelName(model) { throw JudgeRefusal.invalidModel(model) }
        if let pid = runnerPID(id: id) { throw ThreadServiceError.running(pid: pid) }
        do {
            return try await withLog(id) { log in
                try await self.judgeLocked(
                    id: id, log: log, config: config, again: again, budget: budget, model: model,
                    environment: environment, timeout: timeout, attach: attach)
            }
        } catch EventLogError.alreadyOpen { throw JudgeRefusal.busy }
    }

    private func judgeLocked(
        id: String, log: EventLogWriter, config: Config, again: Bool, budget: Decimal, model: String?,
        environment: [String: String], timeout: TimeInterval, attach: @Sendable (AgentExecution) -> Void
    ) async throws -> JudgeResult {
        // A judge a killed process left open ends here, before anything is read or refused.
        try await log.recoverOrphanedEvaluations()
        let events = (try? EventLogReader.read(at: project.eventsURL(id)))?.events ?? []
        let state = ThreadState.derive(from: events, id: id)
        guard state.lastTurn > 0 else { throw JudgeRefusal.noTurn }
        let agent = config.resolvedJudgeAgent(modelFlag: model)
        let turn = state.lastTurn
        if !again, events.contains(where: { $0.kind == .judgeRan && $0.turn == turn && $0.data["ok"] == true }) {
            throw JudgeRefusal.alreadyJudged(turn: turn)
        }
        let goal: Goal
        do {
            goal = try GoalFile.parse(String(contentsOf: project.goalURL(id), encoding: .utf8)).goal
        } catch { throw JudgeRefusal.goalUnreadable("\(error)") }

        let recordedBase = events.last { $0.kind == .worktreeCreated }?.data["base_commit"]?.stringValue
        guard let work = await judgedWork(id: id, base: recordedBase ?? goal.base, recorded: recordedBase != nil) else {
            return try await recordJudge(log, agent: agent, turn: turn, failure: "the diff could not be read", argv: [])
        }
        let cut = work.diff.utf8.count > Judge.diffLimit
        let diffText = cut ? String(decoding: work.diff.utf8.prefix(Judge.diffLimit), as: UTF8.self) : work.diff

        let check = state.review.check
        var checkOutput: String?
        if let check, check.result != "passed" {
            checkOutput = CheckAttachment.load(
                from: project.checkOutputURL(id, turn: check.turn), turn: check.turn, result: check.result,
                exitCode: check.exitCode)?.text
        }
        let verify = state.review.verify
        let (screenshots, folder) = judgeScreenshots(
            id: id, set: Review.ProofSet(verify: verify, verifier: state.review.verifier), lastTurn: turn)
        let input = JudgeInput(
            goal: goal, diff: diffText, diffTruncated: cut, check: check, checkOutput: checkOutput, verify: verify,
            screenshots: screenshots,
            screenshotSizes: Dictionary(
                uniqueKeysWithValues: screenshots.compactMap { name in
                    PNGSize.read(at: folder.appendingPathComponent(name)).map { (name, $0) }
                }),
            lastTurn: turn, untracked: work.untracked)
        let attempts = AttemptLog(log: log, role: "judge", turn: turn, agent: agent)
        // What goes in the log is decided before anything is spent; a refusal is a result, not a spawn.
        let executable = config.executable(for: agent.provider)
        guard let provider = config.agentProvider(agent.provider) else {
            let why = "there is no adapter for \(agent.provider)"
            try await attempts.refused(why)
            return try await recordJudge(log, agent: agent, turn: turn, failure: why, argv: [])
        }
        let spend = AgentSpendPolicy.spend(
            role: .judge, agent: agent, capabilities: provider.capabilities, cap: budget, legacy: false,
            table: config.allowUnpricedTable(.judge))
        let answerFolder = project.threadDirectory(id).appendingPathComponent("judge")
        let request: AgentRequest
        if agent.provider == .codex {
            // Codex has no structured output: it is asked for the same JSON as text, and writes its last message to a file
            // beside the evidence, never inside the folder it reads.
            try? FileManager.default.createDirectory(at: answerFolder, withIntermediateDirectories: true)
            let answer = answerFolder.appendingPathComponent("turn-\(turn).answer.txt")
            try? FileManager.default.removeItem(at: answer)
            request = AgentRequest(
                provider: agent.provider, model: agent.model, prompt: Judge.prompt(for: input, attachedImages: true),
                images: screenshots.map { folder.appendingPathComponent($0) }, workingDirectory: folder,
                outputDirectory: answerFolder, policy: .readOnlyEvidence, spend: (try? spend.get()) ?? .timeoutOnly,
                purpose: .judge, environment: environment,
                limits: AgentLimits(timeout: timeout, maxLineBytes: 1 << 20), answerFile: answer)
        } else {
            request = AgentRequest(
                provider: agent.provider, model: agent.model, prompt: Judge.prompt(for: input),
                workingDirectory: folder, outputDirectory: project.threadDirectory(id), policy: .readOnlyEvidence,
                spend: (try? spend.get()) ?? .hardCap(budget),
                session: .start(proposed: UUID().uuidString.lowercased()), purpose: .judge, environment: environment,
                limits: AgentLimits(timeout: timeout, maxLineBytes: 1 << 20), evidenceFiles: screenshots)
        }
        let shown: [String]
        do {
            if case .failure(let refusal) = spend { throw refusal }
            if let refusal = request.validate(against: provider) { throw refusal }
            shown = try provider.invocation(for: request).displayArguments
        } catch {
            try await attempts.refused(Self.judgeFailureText(error))
            return try await recordJudge(log, agent: agent, turn: turn, failure: Self.judgeFailureText(error), argv: [])
        }
        // An executable that is not there is a refusal: nothing was started.
        guard ExecutableResolver.resolve(executable, searchPath: environment["PATH"]) != nil else {
            let missing = Self.agentMissing(executable, provider: agent.provider)
            try await attempts.refused(missing)
            return try await recordJudge(log, agent: agent, turn: turn, failure: missing, argv: shown)
        }

        // The attempt is on record before anything is spent, and this process is the thread's live holder while it
        // runs (`stop` reaches it, a run or another judge is refused). A `claude` a killed judge left behind is
        // found by its working directory and ended before the next one starts.
        OrphanSweeper.sweep(inside: folder)
        try? writeHolderMarker(id)
        defer { try? FileManager.default.removeItem(at: project.runnerURL(id)) }
        try ThreadStore(project: project).requireNoDoctor()
        try await log.append(
            .judgeStarted, turn: turn,
            data: .object(Self.agentFields(agent, ["argv": .array(shown.map { .string($0) })])))
        let attempt = try await attempts.start()
        let execution: AgentExecution
        do { execution = try AgentRunner.start(provider: provider, request: request) } catch {
            try await attempts.end(attempt, "failed", reason: Self.judgeFailureText(error))
            return try await recordJudge(log, agent: agent, turn: turn, failure: Self.judgeFailureText(error), argv: shown)
        }
        attach(execution)
        let completion = await execution.completion
        try await attempts.end(attempt, AttemptLog.outcome(of: completion.process, failure: completion.failure))
        if let why = Self.judgeProcessProblem(completion.process, timeout: timeout, name: "\(agent.provider)") {
            return try await recordJudge(log, agent: agent, turn: turn, failure: why, argv: shown)
        }
        if let failure = completion.failure {
            return try await recordJudge(log, agent: agent, turn: turn, failure: failure.message, argv: shown)
        }
        var written: String?
        if case .file(let url)? = completion.answer { written = Self.readAnswer(url) }
        guard let answer = completion.summary ?? written else {
            let failure = "the verdict was not usable: no result"
            return try await recordJudge(log, agent: agent, turn: turn, failure: failure, argv: shown)
        }
        do {
            let verdict = try Judge.verdict(fromAnswer: answer, criteria: goal.criteria)
            return try await recordJudge(
                log, agent: agent, turn: turn, verdict: verdict, cost: completion.usage?.costUSD, argv: shown)
        } catch {
            return try await recordJudge(log, agent: agent, turn: turn, failure: "\(error)", argv: shown)
        }
    }

    /// `provider` and `model` (null: the provider's own default) added to the fields of a start or end record.
    static func agentFields(_ agent: ResolvedAgent, _ fields: [String: JSONValue]) -> [String: JSONValue] {
        var data = fields
        data["provider"] = .string("\(agent.provider)")
        data["model"] = agent.model.map { .string($0) } ?? .null
        return data
    }

    private static func judgeFailureText(_ error: Error) -> String {
        (error as? AgentFailure)?.message ?? "\(error)"
    }

    /// Marks this process as the one using the thread, in the file `runnerPID` reads.
    func writeHolderMarker(_ id: String) throws {
        let member = ProcessTree.member(for: getpid())
        let info: [String: Any] = [
            "pid": getpid(), "started_seconds": member?.startSeconds ?? 0, "started_micros": member?.startMicros ?? 0,
        ]
        try JSONSerialization.data(withJSONObject: info, options: [.sortedKeys])
            .write(to: project.runnerURL(id), options: .atomic)
    }

    /// Why a `claude` run produced no answer to read, nil when it ended on its own with status 0.
    static func judgeProcessProblem(_ exit: ProcessExit, timeout: TimeInterval, name: String = "claude") -> String? {
        switch exit.cause {
        case .stopped: return "the judge was stopped"
        case .timedOut: return "\(name) did not answer within \(Int(timeout))s"
        case .natural: break
        }
        switch exit.termination {
        case .exited(0): return nil
        case .exited(let code): return "\(name) exited with status \(code)"
        case .signaled(let signal): return "\(name) was ended by signal \(signal)"
        case .lost: return "\(name) ended in a way that was not recorded"
        }
    }

    /// What the judge is shown of the work: the worktree against the commit it left the base at, so committed
    /// and uncommitted changes to tracked files both count, as in `review`, plus the names of untracked files.
    /// Without a worktree (shipped), the branch against the base.
    private func judgedWork(id: String, base: String, recorded: Bool) async -> (diff: String, untracked: [String])? {
        let manager = WorktreeManager(repoRoot: project.root, git: git)
        guard manager.exists(id) else {
            let range = recorded ? "\(base)..\(WorktreeManager.branch(for: id))" : "\(base)...\(WorktreeManager.branch(for: id))"
            let diff = try? await git.run(["diff", "--no-ext-diff", "--no-color", range], in: project.root)
            guard let diff, diff.succeeded else { return nil }
            return (diff.stdout, [])
        }
        let worktree = manager.path(for: id)
        // The commit the worktree was cut from, as `review` uses, so both see the same work even after the base
        // branch has moved on. Only a thread that predates that record falls back to the branch's merge base.
        var from = base
        if !recorded {
            guard let mergeBase = try? await git.run(["merge-base", base, "HEAD"], in: worktree), mergeBase.succeeded
            else { return nil }
            from = mergeBase.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let diff = try? await git.run(["diff", "--no-ext-diff", "--no-color", from], in: worktree)
        guard let diff, diff.succeeded else { return nil }
        let others = try? await git.run(["ls-files", "--others", "--exclude-standard"], in: worktree)
        let names = (others?.stdout ?? "").split(separator: "\n").map(String.init).prefix(Self.judgeUntrackedLimit)
        return (diff.stdout, Array(names))
    }

    /// The screenshots of the latest turn's proof (the verify step's and the verifier's, the verifier's winning a
    /// name both left) that are still there as recorded, as names relative to the folder the judge runs in, and
    /// that folder. With none, the judge runs in the thread directory and has no tools.
    private func judgeScreenshots(id: String, set: Review.ProofSet?, lastTurn: Int) -> (names: [String], folder: URL) {
        let thread = project.threadDirectory(id)
        guard let set, set.turn == lastTurn else { return ([], thread) }
        let files = set.files.filter {
            !$0.name.contains("/") && $0.name.lowercased().hasSuffix(".png") && $0.bytes <= Self.judgeScreenshotBytes
                && $0.isAvailable(in: thread)
        }
        guard !files.isEmpty else { return ([], thread) }
        return (files.prefix(Self.judgeScreenshotLimit).map(\.name), project.proofDirectory(id, turn: set.turn))
    }

    private func recordJudge(
        _ log: EventLogWriter, agent: ResolvedAgent, turn: Int, verdict: JudgeVerdict? = nil, cost: Double? = nil,
        failure: String? = nil,
        argv: [String]
    ) async throws -> JudgeResult {
        var data = Self.agentFields(agent, ["ok": .bool(verdict != nil), "argv": .array(argv.map { .string($0) })])
        if let cost { data["cost_usd"] = .double(cost) }
        if let verdict {
            data["criteria"] = .array(
                verdict.criteria.map {
                    .object(["id": .string($0.id), "met": .bool($0.met), "evidence": .array($0.evidence.map { .string($0) })])
                })
            data["concerns"] = .array(verdict.concerns.map { .string($0) })
        }
        let reason = failure.map { Self.withoutCredentials(PRBodyBuilder.scrub($0)) }
        if let reason { data["reason"] = .string(reason) }
        try await log.append(.judgeRan, turn: turn, data: .object(data))
        return JudgeResult(turn: turn, verdict: verdict, costUSD: cost, failure: reason)
    }
}
