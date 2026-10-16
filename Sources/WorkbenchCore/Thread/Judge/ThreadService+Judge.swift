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

    public var description: String {
        switch self {
        case .noTurn: "nothing to judge: no turn has run."
        case .alreadyJudged(let turn):
            "turn \(turn) was judged already (`workbench review` shows it). Pass --again to ask once more."
        case .goalUnreadable(let why): "the goal could not be read: \(why)"
        case .invalidModel: "--model needs a model name or alias like \"haiku\""
        }
    }
}

extension ThreadService {
    /// Most screenshots the judge is shown, and the largest it is shown.
    static let judgeScreenshotLimit = 8
    static let judgeScreenshotBytes = 5 << 20

    /// Runs the advisory judge on the latest turn and records `judge.ran`, with the verdict or the reason there
    /// is none. Read-only and separate from the work: its own session and budget, no `numbered turn`, tools
    /// limited to `Read` on the screenshots (or none), and nothing in Workbench acts on what it says.
    ///
    /// It looks at the committed work (`base...workbench/<id>`), the check, the verify step and the screenshots
    /// the verify step left. It runs once per turn unless `again` is set, because it costs money.
    public func judge(
        id: String, config: Config, again: Bool = false, budget: Decimal = Judge.budgetUSD, model: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment, timeout: TimeInterval = Judge.timeout
    ) async throws -> JudgeResult {
        if let model, !SafeNames.isModelName(model) { throw JudgeRefusal.invalidModel(model) }
        if let pid = runnerPID(id: id) { throw ThreadServiceError.running(pid: pid) }
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

        let branch = WorktreeManager.branch(for: id)
        let diff = try? await git.run(["diff", "--no-ext-diff", "--no-color", "\(goal.base)...\(branch)"], in: project.root)
        guard let diff, diff.succeeded else {
            return try await recordJudge(id, turn: turn, failure: "the diff could not be read", argv: [])
        }
        let cut = diff.stdout.utf8.count > Judge.diffLimit
        let diffText = cut ? String(decoding: diff.stdout.utf8.prefix(Judge.diffLimit), as: UTF8.self) : diff.stdout

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
            screenshots: screenshots, lastTurn: turn)
        let arguments = Judge.arguments(
            config: config, prompt: Judge.prompt(for: input), withScreenshots: !screenshots.isEmpty, budget: budget,
            model: model)
        let shown = PRDescriber.displayArguments(arguments)

        guard let claude = ExecutableResolver.resolve(config.claudePath, searchPath: environment["PATH"]) else {
            return try await recordJudge(
                id, turn: turn, failure: JudgeError.claudeNotFound(config.claudePath).description, argv: shown)
        }
        let runner = GitRunner(
            executable: claude, environment: config.childEnvironment(from: environment), timeout: timeout)
        let result: GitResult
        do { result = try await runner.run(arguments, in: folder) } catch GitError.timedOut(_, let seconds) {
            return try await recordJudge(id, turn: turn, failure: "claude did not answer within \(Int(seconds))s", argv: shown)
        } catch { return try await recordJudge(id, turn: turn, failure: "claude could not be started", argv: shown) }
        guard result.succeeded else {
            return try await recordJudge(id, turn: turn, failure: "claude exited with status \(result.status)", argv: shown)
        }
        do {
            let parsed = try Judge.parse(output: result.stdout, criteria: goal.criteria)
            return try await recordJudge(id, turn: turn, verdict: parsed.verdict, cost: parsed.costUSD, argv: shown)
        } catch {
            return try await recordJudge(id, turn: turn, failure: "\(error)", argv: shown)
        }
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
        _ id: String, turn: Int, verdict: JudgeVerdict? = nil, cost: Double? = nil, failure: String? = nil,
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
        try await withLog(id) { log in try await log.append(.judgeRan, turn: turn, data: .object(data)) }
        return JudgeResult(turn: turn, verdict: verdict, costUSD: cost, failure: reason)
    }
}
