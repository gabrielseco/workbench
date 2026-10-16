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
    /// - Parameter attach: called with the running `claude`, so the caller can stop it (Ctrl-C).
    public func judge(
        id: String, config: Config, again: Bool = false, budget: Decimal = Judge.budgetUSD, model: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment, timeout: TimeInterval = Judge.timeout,
        attach: @Sendable (ProcessRun) -> Void = { _ in }
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
        environment: [String: String], timeout: TimeInterval, attach: @Sendable (ProcessRun) -> Void
    ) async throws -> JudgeResult {
        let events = (try? EventLogReader.read(at: project.eventsURL(id)))?.events ?? []
        let state = ThreadState.derive(from: events, id: id)
        guard state.lastTurn > 0 else { throw JudgeRefusal.noTurn }
        let turn = state.lastTurn
        if !again, events.contains(where: { $0.kind == .judgeRan && $0.turn == turn && $0.data["ok"] == true }) {
            throw JudgeRefusal.alreadyJudged(turn: turn)
        }
        let goal: Goal
        do {
            goal = try GoalFile.parse(String(contentsOf: project.goalURL(id), encoding: .utf8)).goal
        } catch { throw JudgeRefusal.goalUnreadable("\(error)") }

        guard let work = await judgedWork(id: id, base: goal.base) else {
            return try await recordJudge(log, turn: turn, failure: "the diff could not be read", argv: [])
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
        let (screenshots, folder) = judgeScreenshots(id: id, verify: verify, lastTurn: turn)
        let input = JudgeInput(
            goal: goal, diff: diffText, diffTruncated: cut, check: check, checkOutput: checkOutput, verify: verify,
            screenshots: screenshots, lastTurn: turn, untracked: work.untracked)
        let arguments = Judge.arguments(
            config: config, prompt: Judge.prompt(for: input), withScreenshots: !screenshots.isEmpty, budget: budget,
            model: model)
        let shown = PRDescriber.displayArguments(arguments)

        guard let claude = ExecutableResolver.resolve(config.claudePath, searchPath: environment["PATH"]) else {
            return try await recordJudge(
                log, turn: turn, failure: JudgeError.claudeNotFound(config.claudePath).description, argv: shown)
        }
        var request = SpawnRequest(
            executable: claude, arguments: arguments, environment: config.childEnvironment(from: environment),
            workingDirectory: folder, timeout: timeout)
        request.maxLineBytes = 1 << 20
        let run: ProcessRun
        do { run = try ProcessRunner.start(request) } catch {
            return try await recordJudge(log, turn: turn, failure: "claude could not be started", argv: shown)
        }
        attach(run)
        var lines: [String] = []
        var exit: ProcessExit?
        for await event in run.events {
            switch event {
            case .line(let line): lines.append(line)
            case .exited(let e): exit = e
            case .started, .oversizedLine: break
            }
        }
        if let why = Self.judgeProcessProblem(exit, timeout: timeout) {
            return try await recordJudge(log, turn: turn, failure: why, argv: shown)
        }
        do {
            let parsed = try Judge.parse(output: lines.joined(separator: "\n"), criteria: goal.criteria)
            return try await recordJudge(log, turn: turn, verdict: parsed.verdict, cost: parsed.costUSD, argv: shown)
        } catch {
            return try await recordJudge(log, turn: turn, failure: "\(error)", argv: shown)
        }
    }

    /// Why a `claude` run produced no answer to read, nil when it ended on its own with status 0.
    static func judgeProcessProblem(_ exit: ProcessExit?, timeout: TimeInterval) -> String? {
        guard let exit else { return "claude did not report how it ended" }
        switch exit.cause {
        case .stopped: return "the judge was stopped"
        case .timedOut: return "claude did not answer within \(Int(timeout))s"
        case .natural: break
        }
        switch exit.termination {
        case .exited(0): return nil
        case .exited(let code): return "claude exited with status \(code)"
        case .signaled(let signal): return "claude was ended by signal \(signal)"
        case .lost: return "claude ended in a way that was not recorded"
        }
    }

    /// What the judge is shown of the work: the worktree against the commit it left the base at, so committed
    /// and uncommitted changes to tracked files both count, as in `review`, plus the names of untracked files.
    /// Without a worktree (shipped), the branch against the base.
    private func judgedWork(id: String, base: String) async -> (diff: String, untracked: [String])? {
        let manager = WorktreeManager(repoRoot: project.root, git: git)
        guard manager.exists(id) else {
            let diff = try? await git.run(
                ["diff", "--no-ext-diff", "--no-color", "\(base)...\(WorktreeManager.branch(for: id))"], in: project.root)
            guard let diff, diff.succeeded else { return nil }
            return (diff.stdout, [])
        }
        let worktree = manager.path(for: id)
        guard let mergeBase = try? await git.run(["merge-base", base, "HEAD"], in: worktree), mergeBase.succeeded
        else { return nil }
        let from = mergeBase.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let diff = try? await git.run(["diff", "--no-ext-diff", "--no-color", from], in: worktree)
        guard let diff, diff.succeeded else { return nil }
        let others = try? await git.run(["ls-files", "--others", "--exclude-standard"], in: worktree)
        let names = (others?.stdout ?? "").split(separator: "\n").map(String.init).prefix(Self.judgeUntrackedLimit)
        return (diff.stdout, Array(names))
    }

    /// The screenshots of the verify step of the latest turn that are still there as recorded, as names relative
    /// to the folder the judge runs in, and that folder. With none, the judge runs in the thread directory and
    /// has no tools.
    private func judgeScreenshots(id: String, verify: Review.Verify?, lastTurn: Int) -> (names: [String], folder: URL) {
        let thread = project.threadDirectory(id)
        guard let verify, verify.turn == lastTurn else { return ([], thread) }
        let files = verify.proof.filter {
            $0.name.lowercased().hasSuffix(".png") && $0.bytes <= Self.judgeScreenshotBytes && $0.isAvailable(in: thread)
        }
        guard !files.isEmpty else { return ([], thread) }
        return (files.prefix(Self.judgeScreenshotLimit).map(\.name), project.proofDirectory(id, turn: verify.turn))
    }

    private func recordJudge(
        _ log: EventLogWriter, turn: Int, verdict: JudgeVerdict? = nil, cost: Double? = nil, failure: String? = nil,
        argv: [String]
    ) async throws -> JudgeResult {
        var data: [String: JSONValue] = [
            "ok": .bool(verdict != nil), "argv": .array(argv.map { .string($0) }),
        ]
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
