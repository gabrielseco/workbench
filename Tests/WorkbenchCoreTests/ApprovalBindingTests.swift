import Foundation
import Testing

@testable import WorkbenchCore

/// Approval binds the coding provider and model the config picks, and a session belongs to the provider that made it.
@Suite(.processGate) struct ApprovalBindingTests {
    private func setModel(_ model: String?, in fx: RunnerFixture) throws {
        var text = try String(contentsOf: fx.project.configURL, encoding: .utf8)
        text = text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("model = ") }.joined(separator: "\n")
        if let model { text = "model = \"\(model)\"\n" + text }
        try text.write(to: fx.project.configURL, atomically: true, encoding: .utf8)
    }

    private func approvals(_ fx: RunnerFixture, _ id: String) throws -> [Event] {
        try fx.events(id).filter { $0.kind == .goalApproved }
    }

    @Test func approveRecordsResolvedAgent() async throws {
        let fx = try await RunnerFixture(extraConfig: "model = \"opus\"")
        let id = try await fx.approvedThread()
        let event = try #require(approvals(fx, id).last)
        #expect(event.data["provider"] == "claude" && event.data["model"] == "opus")
        #expect(ThreadStore(project: fx.project).state(of: id).approvedAgent == ApprovedAgent(provider: "claude", model: "opus"))
        #expect(LogFormatter.describe(event).hasSuffix("goal approved for coding on claude, opus"))
    }

    @Test func runRefusesChangedAgent() async throws {
        let fx = try await RunnerFixture(extraConfig: "model = \"opus\"")
        let id = try await fx.approvedThread()
        try setModel("haiku", in: fx)
        let error = await #expect(throws: RunnerError.self) { _ = try await fx.runner(id).run(fx.options()) }
        #expect(error == .codingSettingsChanged(approved: "claude, opus", now: "claude, haiku"))
        #expect(error?.description.contains("workbench goal approve") == true)
        #expect(try fx.kinds(id).filter { $0 == "turn.started" }.isEmpty, "nothing ran")
    }

    @Test func reapproveAfterConfigChange() async throws {
        let fx = try await RunnerFixture(extraConfig: "model = \"opus\"")
        let id = try await fx.approvedThread()
        let goalBefore = try String(contentsOf: fx.project.goalURL(id), encoding: .utf8)
        try setModel(nil, in: fx)
        try await fx.service.approve(id: id)
        #expect(try String(contentsOf: fx.project.goalURL(id), encoding: .utf8) == goalBefore, "the goal file is untouched")
        let all = try approvals(fx, id)
        #expect(all.count == 2 && all[1].data["model"] == .null && all[1].data["hash"] == all[0].data["hash"])
        let report = try await fx.runner(id).run(fx.options())
        #expect(report.result == .succeeded)
    }

    @Test func approveTwiceWritesOnce() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        try await fx.service.approve(id: id)
        #expect(try approvals(fx, id).count == 1)
    }

    @Test func legacyApprovalStillRuns() async throws {
        let fx = try await RunnerFixture(extraConfig: "model = \"opus\"")
        let id = try await fx.approvedThread()
        // An approval written before the settings were recorded: rewrite the log line without them.
        let url = fx.project.eventsURL(id)
        let text = try String(contentsOf: url, encoding: .utf8)
        let stripped = text.split(separator: "\n").map { line -> String in
            guard line.contains("\"goal.approved\"") else { return String(line) }
            return String(line).replacingOccurrences(of: ",\"provider\":\"claude\"", with: "")
                .replacingOccurrences(of: ",\"model\":\"opus\"", with: "")
                .replacingOccurrences(of: "\"model\":\"opus\",", with: "")
                .replacingOccurrences(of: "\"provider\":\"claude\",", with: "")
        }.joined(separator: "\n") + "\n"
        try stripped.write(to: url, atomically: true, encoding: .utf8)
        #expect(ThreadStore(project: fx.project).state(of: id).approvedAgent == nil)
        try setModel("haiku", in: fx)
        let report = try await fx.runner(id).run(fx.options())
        #expect(report.result == .succeeded)
    }

    @Test func evaluationSettingsDoNotInvalidate() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        var text = try String(contentsOf: fx.project.configURL, encoding: .utf8)
        text += "\n[agents.judge]\nmodel = \"haiku\"\n\n[agents.review]\nprovider = \"codex\"\n"
        try text.write(to: fx.project.configURL, atomically: true, encoding: .utf8)
        let report = try await fx.runner(id).run(fx.options())
        #expect(report.result == .succeeded)
    }

    @Test func oldLogReplays() throws {
        let withSettings: [Event] = [
            Event(seq: 1, ts: "2026-10-24T10:00:00.000Z", turn: 0, kind: .goalApproved,
                  data: ["hash": "h", "budget_usd": 1.0, "provider": "claude", "model": .null]),
        ]
        let without: [Event] = [
            Event(seq: 1, ts: "2026-10-24T10:00:00.000Z", turn: 0, kind: .goalApproved, data: ["hash": "h", "budget_usd": 1.0]),
        ]
        var a = ThreadState.derive(from: withSettings, id: "t")
        let b = ThreadState.derive(from: without, id: "t")
        #expect(a.approvedGoalHash == b.approvedGoalHash && b.approvedAgent == nil)
        a.approvedAgent = nil
        #expect(a == b)
    }

    // MARK: sessions

    private func logTurn(_ fx: RunnerFixture, _ id: String, session: String, provider: String?) async throws {
        let log = try EventLogWriter.open(at: fx.project.eventsURL(id))
        var data: [String: JSONValue] = ["session_id": .string(session), "resume": false]
        if let provider { data["provider"] = .string(provider) }
        try await log.append(.turnStarted, turn: 1, data: .object(data))
        await log.close()
    }

    @Test func otherProviderHandleNotResumed() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        let store = ThreadStore(project: fx.project)
        try store.save(.init(sessionID: "11111111-1111-1111-1111-111111111111", confirmed: true, provider: "codex"), for: id)
        #expect(ThreadRunner.resumableSession(store: store, threadID: id, provider: .claude) == nil)
        #expect(ThreadRunner.resumableSession(store: store, threadID: id, provider: AgentProviderID("codex")!)?.confirmed == true)

        let report = try await fx.runner(id).run(fx.options())
        #expect(report.result == .succeeded)
        let started = try #require(fx.events(id).first { $0.kind == .turnStarted })
        #expect(started.data["resume"] == false && started.data["session_id"] != "11111111-1111-1111-1111-111111111111")
        #expect(store.session(of: id)?.provider == "claude")
    }

    @Test func aHandleWithoutAProviderIsClaudes() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        let store = ThreadStore(project: fx.project)
        try store.save(.init(sessionID: "s1", confirmed: true), for: id)
        #expect(ThreadRunner.resumableSession(store: store, threadID: id, provider: .claude)?.sessionID == "s1")
    }

    @Test func logWinsOverSessionFile() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        let store = ThreadStore(project: fx.project)
        try await logTurn(fx, id, session: "22222222-2222-2222-2222-222222222222", provider: "claude")
        try store.save(.init(sessionID: "from-file", confirmed: true, provider: "claude"), for: id)
        let chosen = try #require(ThreadRunner.resumableSession(store: store, threadID: id, provider: .claude))
        #expect(chosen.sessionID == "22222222-2222-2222-2222-222222222222" && !chosen.confirmed, "an unconfirmed id keeps the safe fallback")
        let logged = "22222222-2222-2222-2222-222222222222"
        try store.save(.init(sessionID: logged, confirmed: true, provider: "claude"), for: id)
        #expect(ThreadRunner.resumableSession(store: store, threadID: id, provider: .claude)?.confirmed == true)
    }

    @Test func aLoggedOtherProviderSessionIsNotResumed() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        try await logTurn(fx, id, session: "x", provider: "codex")
        let store = ThreadStore(project: fx.project)
        #expect(ThreadRunner.resumableSession(store: store, threadID: id, provider: .claude) == nil)
    }

    @Test func theLoggedSessionSurvivesAMissingSessionFile() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        let store = ThreadStore(project: fx.project)
        let uuid = "33333333-3333-3333-3333-333333333333"
        try await logTurn(fx, id, session: uuid, provider: "claude")
        #expect(store.session(of: id) == nil)
        let chosen = try #require(ThreadRunner.resumableSession(store: store, threadID: id, provider: .claude))
        #expect(chosen.sessionID == uuid && !chosen.confirmed)
        try "not json".write(to: fx.project.sessionURL(id), atomically: true, encoding: .utf8)
        #expect(ThreadRunner.resumableSession(store: store, threadID: id, provider: .claude)?.sessionID == uuid)
    }
}
