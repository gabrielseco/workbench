import Foundation
import Testing

@testable import WorkbenchCore

private func ev(_ seq: Int, _ turn: Int, _ kind: EventKind, _ data: JSONValue = [:]) -> Event {
    Event(seq: seq, ts: "2026-10-24T10:00:\(String(format: "%02d", seq % 60)).000Z", turn: turn, kind: kind, data: data)
}

private func cliJSON(_ arguments: [String], in fx: RunnerFixture) async throws -> [String: Any] {
    let ran = try await workbenchCLI(
        arguments + ["--json"], in: fx.repo,
        environment: ["PATH": "/usr/bin:/bin", "HOME": fx.repo.path, "USER": NSUserName(), "FAKE_CLAUDE": ""])
    #expect(ran.code == 0, "\(ran.stdout) \(ran.stderr)")
    return try #require(JSONSerialization.jsonObject(with: Data(ran.stdout.utf8)) as? [String: Any])
}

@Suite(.processGate) struct AgentVisibilityTests {
    private let attemptsLog: [Event] = [
        ev(1, 0, .goalApproved, ["hash": "h", "budget_usd": 1.0, "provider": "claude", "model": "opus"]),
        ev(2, 1, .turnStarted, ["provider": "claude", "model": "opus", "session_id": "s", "resume": false]),
        ev(3, 1, .agentAttemptStarted, ["attempt": "a3", "role": "run", "provider": "claude", "model": "opus"]),
        ev(
            4, 1, .agentAttemptEnded,
            ["attempt": "a3", "role": "run", "provider": "claude", "model": "opus", "outcome": "succeeded"]),
        ev(5, 1, .turnEnded, ["result": "succeeded"]),
        ev(6, 1, .judgeStarted, ["provider": "claude", "model": "haiku"]),
        ev(7, 1, .agentAttemptStarted, ["attempt": "a7", "role": "judge", "provider": "claude", "model": "haiku"]),
        ev(
            8, 1, .agentAttemptEnded,
            ["attempt": "a7", "role": "judge", "provider": "claude", "model": "haiku", "outcome": "failed"]),
        ev(
            9, 1, .agentAttemptStarted,
            ["attempt": "a9", "role": "review", "stage": "design", "round": 2, "provider": "codex", "model": .null]),
    ]

    @Test func derivesAgentPerRole() {
        let state = ThreadState.derive(from: attemptsLog, id: "t")
        #expect(
            state.agentUse["run"]
                == AgentUse(
                    provider: "claude", model: "opus", recorded: true, turn: 1, attempt: "a3", outcome: "succeeded"))
        let judge = state.agentUse["judge"]
        #expect(
            judge?.model == "haiku" && judge?.outcome == "failed" && judge?.attempt == "a7",
            "the attempt wins over judge.started")
        let review = state.agentUse["review"]
        #expect(review?.provider == "codex" && review?.model == nil && review?.stage == "design" && review?.round == 2)
        #expect(review?.outcome == nil, "an attempt with no end has no outcome yet")
    }

    @Test func derivesApprovedFor() {
        let state = ThreadState.derive(from: attemptsLog, id: "t")
        #expect(state.approvedFor == AgentUse(provider: "claude", model: "opus", recorded: true))
        let later = attemptsLog + [ev(10, 0, .goalApproved, ["hash": "h", "provider": "claude", "model": .null])]
        #expect(ThreadState.derive(from: later, id: "t").approvedFor?.model == nil, "the latest approval counts")
        #expect(ThreadState.derive(from: [], id: "t").approvedFor == nil)
    }

    @Test func legacyLogReadsAsClaudeDefault() {
        let events = [
            ev(1, 0, .goalApproved, ["hash": "h", "budget_usd": 1.0]),
            ev(2, 1, .turnStarted, ["session_id": "s", "resume": false, "pid": 1]),
            ev(3, 1, .turnEnded, ["result": "succeeded"]),
            ev(4, 1, .judgeStarted, ["argv": ["claude"]]),
            ev(5, 1, .judgeRan, ["ok": true]),
            ev(6, 1, .prReviewStarted, ["round": 1, "pr": 3]),
        ]
        let state = ThreadState.derive(from: events, id: "t")
        #expect(state.agentUse["run"] == AgentUse(provider: "claude", model: nil, recorded: false, turn: 1))
        #expect(state.agentUse["judge"]?.provider == "claude" && state.agentUse["judge"]?.recorded == false)
        #expect(state.agentUse["review"]?.provider == "codex" && state.agentUse["review"]?.recorded == false)
        #expect(state.approvedFor == AgentUse(provider: "claude", model: nil, recorded: false))
        let lines = state.agentLines()
        #expect(lines.count == 4 && lines.allSatisfy { $0.contains("the provider's default") })
        #expect(lines.allSatisfy { $0.contains("not recorded") })
        #expect(ThreadState.derive(from: [], id: "t").agentLines().isEmpty, "a role that never ran is not invented")
    }

    @Test func refusedAttemptIsNotRun() {
        let events = [
            ev(
                1, 0, .agentAttemptStarted,
                ["attempt": "a1", "role": "judge", "provider": "claude", "model": .null, "spawned": false]),
            ev(
                2, 0, .agentAttemptEnded,
                ["attempt": "a1", "role": "judge", "outcome": "refused", "reason": "no claude"]),
        ]
        let use = ThreadState.derive(from: events, id: "t").agentUse["judge"]
        #expect(use?.spawned == false && use?.outcome == "refused")
        #expect(use?.description.contains("refused: nothing was started") == true)
    }

    @Test func statusJSONHasAgents() async throws {
        let fx = try await RunnerFixture(extraConfig: "model = \"opus\"")
        let id = try await fx.approvedThread()
        _ = try await fx.runner(id).run(fx.options())
        let status = try await cliJSON(["status"], in: fx)
        let agents = try #require(status["agents"] as? [String: Any])
        #expect(Set(agents.keys) == ["run", "judge", "review"])
        let run = try #require(agents["run"] as? [String: Any])
        #expect(run["provider"] as? String == "claude" && run["model"] as? String == "opus")
        #expect(
            run["recorded"] as? Bool == true && run["outcome"] as? String == "succeeded"
                && run["spawned"] as? Bool == true)
        #expect(agents["judge"] is NSNull && agents["review"] is NSNull, "never ran: null")
        let approved = try #require(status["approved_for"] as? [String: Any])
        #expect(approved["provider"] as? String == "claude" && approved["model"] as? String == "opus")
        #expect(status["thread"] as? String == id)
    }

    @Test func reviewJSONHasAgents() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        _ = try await fx.runner(id).run(fx.options())
        let review = try await cliJSON(["review"], in: fx)
        let run = try #require((review["agents"] as? [String: Any])?["run"] as? [String: Any])
        #expect(run["provider"] as? String == "claude" && run["model"] is NSNull && run["recorded"] as? Bool == true)
        #expect((review["approved_for"] as? [String: Any])?["recorded"] as? Bool == true)
    }

    @Test func textShowsAgents() async throws {
        let fx = try await RunnerFixture(extraConfig: "model = \"opus\"")
        let id = try await fx.approvedThread()
        _ = try await fx.runner(id).run(fx.options())
        let environment = ["PATH": "/usr/bin:/bin", "HOME": fx.repo.path, "USER": NSUserName(), "FAKE_CLAUDE": ""]
        for command in ["status", "review"] {
            let ran = try await workbenchCLI([command], in: fx.repo, environment: environment)
            #expect(ran.code == 0, "\(ran.stderr)")
            let lines = ran.stdout.split(separator: "\n").map(String.init)
            #expect(
                lines.contains { $0.hasPrefix("approved for: ") && $0.contains("claude, model opus") },
                "\(command): \(ran.stdout)")
            #expect(
                lines.contains { $0.hasPrefix("agent run:") && $0.contains("claude, model opus (succeeded)") },
                "\(command)")
            #expect(!lines.contains { $0.hasPrefix("agent judge:") }, "\(command): the judge never ran")
        }
        _ = id
    }
}
