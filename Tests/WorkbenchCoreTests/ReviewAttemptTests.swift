import Foundation
import Testing

@testable import WorkbenchCore

@Suite(.processGate) struct ReviewAttemptTests {
    private func attempts(_ r: ReviewedPR) throws -> [Event] {
        // The thread's own coding turn has an attempt too; these are the review's. An end names its attempt only.
        let all = try r.fx.events(r.id).filter { $0.kind == .agentAttemptStarted || $0.kind == .agentAttemptEnded }
        let reviews = Set(all.filter { $0.data["role"] == "review" }.compactMap { $0.data["attempt"]?.stringValue })
        return all.filter { reviews.contains($0.data["attempt"]?.stringValue ?? "") }
    }

    @Test func aRoundAndItsAttemptCarryTheProviderAndModel() async throws {
        let r = try await reviewedPR()
        _ = try await r.round()
        let started = try #require(r.started.first), finished = try #require(r.finished.first)
        #expect(started.data["provider"] == "codex" && started.data["model"] == .null)
        #expect(finished.data["provider"] == "codex" && finished.data["model"] == .null)
        let pair = try attempts(r)
        #expect(pair.map(\.kind) == [.agentAttemptStarted, .agentAttemptEnded])
        #expect(pair[0].data["role"] == "review" && pair[0].data["round"]?.intValue == 1 && pair[0].data["stage"] == nil)
        #expect(pair[1].data["outcome"] == "succeeded" && pair[1].data["attempt"] == pair[0].data["attempt"])
    }

    @Test func capacityRetryIsAnAttemptNotARound() async throws {
        let r = try await reviewedPR()
        try r.codex.put("capacity_until", "1")
        let result = try await r.round()
        #expect(result.round == 1 && result.verdict == .clean)
        #expect(r.started.count == 1 && r.finished.count == 1, "one round, however many tries")
        let pairs = try attempts(r)
        #expect(pairs.map(\.kind) == [.agentAttemptStarted, .agentAttemptEnded, .agentAttemptStarted, .agentAttemptEnded])
        #expect(pairs[1].data["outcome"] == "failed" && pairs[3].data["outcome"] == "succeeded")
        #expect(Set(pairs.compactMap { $0.data["attempt"]?.stringValue }).count == 2)
        #expect(pairs.allSatisfy { $0.data["round"] == nil || $0.data["round"]?.intValue == 1 })
        #expect(r.codex.runs == 2)
    }

    @Test func aMissingCodexIsARefusedAttemptWithNoProcess() async throws {
        let r = try await reviewedPR()
        let result = try await r.round(codexPath: "/no/such/codex")
        #expect(result.failure?.contains("was not found") == true)
        let pair = try attempts(r)
        #expect(pair.map(\.kind) == [.agentAttemptStarted, .agentAttemptEnded])
        #expect(pair[0].data["spawned"] == false && pair[1].data["outcome"] == "refused")
        #expect(r.codex.runs == 0)
    }

    @Test func aLaunchFailureAfterTheStartClosesTheAttempt() async throws {
        let r = try await reviewedPR()
        let bad = r.codex.dir.appendingPathComponent("bad-codex")
        try "#!/no/such/interpreter\n".write(to: bad, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bad.path)
        let result = try await r.round(codexPath: bad.path)
        #expect(result.verdict == nil && result.failure != nil)
        let events = try attempts(r)
        let opened = events.filter { $0.kind == .agentAttemptStarted }.count
        let closed = events.filter { $0.kind == .agentAttemptEnded }.count
        #expect(opened == closed && opened >= 1, "every attempt that was started was closed")
        #expect(events.last?.data["outcome"] == "failed")
        #expect(r.finished.count == 1)
    }

    @Test func aKilledRoundIsClosedAndStillCounts() async throws {
        let r = try await reviewedPR()
        let log = try EventLogWriter.open(at: r.fx.project.eventsURL(r.id))
        try await log.append(
            .prReviewStarted, turn: 1,
            data: ["round": 1, "pr": 12, "head_sha": .string(r.head), "provider": "codex", "model": .null])
        try await log.startAttempt(role: "review", turn: 1, round: 1, provider: .codex, model: nil)
        await log.close()

        let result = try await r.round(again: true)
        #expect(result.round == 2, "the interrupted round counted toward the cap")
        let events = try r.fx.events(r.id)
        let synthetic = try #require(events.first { $0.kind == .prReviewFinished && $0.data["synthetic"] == true })
        #expect(synthetic.data["ok"] == false && synthetic.data["reason"] == "interrupted")
        #expect(synthetic.data["round"]?.intValue == 1)
        #expect(events.filter { $0.kind == .prReviewStarted }.count == 2)
        #expect(try r.fx.contents(r.id).isHealthy)
    }
}
