import Foundation
import Testing

@testable import WorkbenchCore

/// A judge or review a killed process left open, on each provider of the new pairs (P9 PR 13): closed exactly once,
/// as `interrupted`, before the next one starts; the round still counts.
@Suite(.processGate) struct AgentRecoveryProvidersTests {
    private let oneCriterion = #"{"criteria": [{"id": "c1", "met": true, "evidence": []}], "concerns": []}"#

    private func killedJudge(_ fx: RunnerFixture, _ id: String, provider: AgentProviderID) async throws {
        let log = try EventLogWriter.open(at: fx.project.eventsURL(id))
        try await log.append(.judgeStarted, turn: 1, data: ["argv": ["x"], "provider": .string("\(provider)"), "model": .null])
        try await log.startAttempt(role: "judge", turn: 1, provider: provider, model: nil)
        await log.close()
    }

    private func closedOnce(_ events: [Event], role: String) -> Bool {
        let started = events.filter { $0.kind == .agentAttemptStarted && $0.data["role"]?.stringValue == role }
        return started.allSatisfy { start in
            let attempt = start.data["attempt"]?.stringValue
            return events.filter { $0.kind == .agentAttemptEnded && $0.data["attempt"]?.stringValue == attempt }.count == 1
        }
    }

    @Test func interruptedJudgeCodex() async throws {
        let fx = try await RunnerFixture()
        let (id, _) = try await acceptedThread(fx)
        let codex = try FakeCodex(in: fx)
        try codex.put("answer", oneCriterion)
        var config = try Config.load(from: fx.project.configURL)
        config.agents.judge = AgentSelection(provider: .codex, allowUnpriced: true)
        config.agents.executables[.codex] = codex.path
        try await killedJudge(fx, id, provider: .codex)

        let result = try await fx.service.judge(id: id, config: config, environment: codex.environment())
        #expect(result.verdict != nil, "the interrupted judge did not count as having judged the turn")
        let events = try fx.events(id)
        let synthetic = events.filter { $0.kind == .judgeRan && $0.data["synthetic"] == true }
        #expect(synthetic.count == 1 && synthetic[0].data["reason"] == "interrupted" && synthetic[0].data["provider"] == "codex")
        #expect(events.filter { $0.kind == .judgeStarted }.count == 2 && events.filter { $0.kind == .judgeRan }.count == 2)
        #expect(closedOnce(events, role: "judge"))
        #expect(try fx.contents(id).isHealthy)
    }

    @Test func interruptedReviewClaude() async throws {
        var r = try await reviewedPR()
        r.config.agents.review = AgentSelection(provider: .claude)
        let file = r.codex.dir.appendingPathComponent("answer.txt")
        try "Fine.\nVERDICT: CLEAN\n".write(to: file, atomically: true, encoding: .utf8)
        let log = try EventLogWriter.open(at: r.fx.project.eventsURL(r.id))
        try await log.append(
            .prReviewStarted, turn: 1,
            data: ["round": 1, "pr": 12, "head_sha": .string(r.head), "provider": "claude", "model": .null])
        try await log.startAttempt(role: "review", turn: 1, round: 1, provider: .claude, model: nil)
        await log.close()

        let result = try await r.round(again: true, environment: r.codex.environment(["FAKE_CLAUDE": "answer=\(file.path)"]))
        #expect(result.round == 2 && result.verdict == .clean, "the interrupted round counted toward the cap")
        let events = try r.fx.events(r.id)
        let synthetic = events.filter { $0.kind == .prReviewFinished && $0.data["synthetic"] == true }
        #expect(synthetic.count == 1 && synthetic[0].data["reason"] == "interrupted" && synthetic[0].data["round"]?.intValue == 1)
        #expect(synthetic[0].data["provider"] == "claude")
        #expect(closedOnce(events, role: "review"))
        #expect(try r.fx.contents(r.id).isHealthy)
    }

    @Test func recoveryIsIdempotent() async throws {
        let fx = try await RunnerFixture()
        let (id, _) = try await acceptedThread(fx)
        try await killedJudge(fx, id, provider: .codex)
        let log = try EventLogWriter.open(at: fx.project.eventsURL(id))
        try await log.recoverOrphanedEvaluations()
        let once = try fx.events(id).count
        try await log.recoverOrphanedEvaluations()
        try await log.recoverOrphanedEvaluations()
        await log.close()
        let events = try fx.events(id)
        #expect(events.count == once, "repeating recovery writes nothing")
        #expect(events.filter { $0.kind == .judgeRan }.count == 1 && closedOnce(events, role: "judge"))
        let seqs = events.map(\.seq)
        #expect(seqs == Array(seqs.first!...seqs.last!), "no gap in the sequence")
    }
}
