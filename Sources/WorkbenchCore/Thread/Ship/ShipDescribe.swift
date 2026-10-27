import Foundation

/// What the describing turn produced, or why `ship` goes on with the goal-based body instead.
public struct PRDescribeResult: Sendable, Equatable {
    /// Nil when the turn failed; `fallback` says why.
    public var description: PRDescription?
    public var fallback: String?
}

extension ThreadService {
    /// Runs the describing turn for a thread about to ship and records a `pr.described` event with how it
    /// went. It never throws for a failed turn: a missing agent, a timeout, a budget stop or an unusable
    /// answer all come back as a `fallback` reason, because shipping must not depend on it.
    ///
    /// The turn is read-only and separate from the work: no tools, its own session and budget (on Claude; on Codex
    /// its timeout), and it is recorded as its own event, not as a numbered turn, so `turns` and the work session are
    /// unchanged. `attach` is called with the running process, so the caller can stop it (Ctrl-C).
    public func describePR(
        plan: ShipPlan, config: Config, environment: [String: String] = ProcessInfo.processInfo.environment,
        timeout: TimeInterval = PRDescriber.timeout, attach: @Sendable (ProcessRun) -> Void = { _ in }
    ) async throws -> PRDescribeResult {
        let agent = config.resolvedShipAgent
        let events = (try? EventLogReader.read(at: project.eventsURL(plan.id)))?.events ?? []
        let goal: Goal
        do {
            goal = try GoalFile.parse(String(contentsOf: project.goalURL(plan.id), encoding: .utf8)).goal
        } catch { return try await record(plan, agent: agent, fail: "the goal could not be read", argv: []) }
        let state = ThreadState.derive(from: events, id: plan.id)

        let range = "\(plan.base)...\(plan.head)"
        let diff = try? await git.run(["diff", "--no-ext-diff", "--no-color", range], in: plan.worktree)
        let log = try? await git.run(["log", "--format=%s", "\(plan.base)..\(plan.head)"], in: plan.worktree)
        guard let diff, diff.succeeded else {
            return try await record(plan, agent: agent, fail: "the diff could not be read", argv: [])
        }
        let cut = diff.stdout.utf8.count > PRDescriber.diffLimit
        let diffText = cut ? String(decoding: diff.stdout.utf8.prefix(PRDescriber.diffLimit), as: UTF8.self) : diff.stdout

        let input = PRDescribeInput(
            goal: goal, notes: state.review.notes.map(\.text), turnResult: state.review.turnResult,
            commits: (log?.stdout ?? "").split(separator: "\n").map(String.init), diff: diffText,
            diffTruncated: cut, check: state.review.check)
        let turn = await runPRTurn(
            id: plan.id, worktree: plan.worktree, prompt: PRDescriber.prompt(for: input), config: config,
            environment: environment, timeout: timeout, attach: attach)
        guard let text = turn.text else {
            return try await record(plan, agent: agent, fail: turn.failure ?? "no answer", argv: turn.argv)
        }
        do {
            let description = try PRDescriber.parse(answer: text)
            try await withLog(plan.id) { log in
                try await log.append(
                    .prDescribed,
                    data: .object(
                        Self.agentFields(
                            agent,
                            [
                                "ok": true, "argv": .array(turn.argv.map { .string($0) }),
                                "title": .string(description.title),
                            ])))
            }
            return PRDescribeResult(description: description, fallback: nil)
        } catch {
            return try await record(plan, agent: agent, fail: "\(error)", argv: turn.argv)
        }
    }

    private func record(
        _ plan: ShipPlan, agent: ResolvedAgent, fail reason: String, argv: [String]
    ) async throws -> PRDescribeResult {
        let reason = Self.withoutCredentials(PRBodyBuilder.scrub(reason))
        try await withLog(plan.id) { log in
            try await log.append(
                .prDescribed,
                data: .object(
                    Self.agentFields(
                        agent, ["ok": false, "reason": .string(reason), "argv": .array(argv.map { .string($0) })])))
        }
        return PRDescribeResult(description: nil, fallback: reason)
    }
}
