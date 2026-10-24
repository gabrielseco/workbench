import Foundation

/// The `agent.attempt.*` records of one responsibility's provider process: one attempt per physical start, so a
/// capacity retry has its own and adds no round or turn. Written by whoever holds the thread's log.
struct AttemptLog: Sendable {
    let log: EventLogWriter
    let role: String
    var stage: String?
    var turn = 0
    var round: Int?
    let agent: ResolvedAgent

    /// On record before the process is started.
    func start() async throws -> String {
        try await log.startAttempt(
            role: role, stage: stage, turn: turn, round: round, provider: agent.provider, model: agent.model)
    }

    /// Something refused to start (no executable, a request the provider cannot take): a pair that says nothing ran.
    func refused(_ reason: String) async throws {
        let id = try await log.startAttempt(
            role: role, stage: stage, turn: turn, round: round, provider: agent.provider, model: agent.model,
            spawned: false)
        try await log.endAttempt(id, outcome: "refused", reason: Self.safe(reason))
    }

    func end(_ id: String, _ outcome: String, reason: String? = nil) async throws {
        try await log.endAttempt(id, outcome: outcome, reason: reason.map(Self.safe))
    }

    /// What the process did, whatever the answer made of it.
    static func outcome(of exit: ProcessExit, failure: AgentFailure? = nil) -> String {
        switch exit.cause {
        case .stopped: return "stopped"
        case .timedOut: return "timed_out"
        case .natural: break
        }
        if failure != nil { return "failed" }
        if case .exited(0) = exit.termination { return "succeeded" }
        return "failed"
    }

    private static func safe(_ text: String) -> String {
        String(ThreadService.withoutCredentials(PRBodyBuilder.scrub(text)).prefix(300))
    }
}
