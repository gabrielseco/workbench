import Foundation
import Testing

@testable import WorkbenchCore

/// Approval binds the coding provider and model the config picks, and a session belongs to the provider that made it.
@Suite(.processGate) struct ApprovalBindingTests {
    private static let runModel = "[agents.run]\nmodel = \"opus\""

    /// Rewrites `[agents.run] model`, the only `model` these fixtures set; nil removes the table.
    private func setModel(_ model: String?, in fx: RunnerFixture) throws {
        var text = try String(contentsOf: fx.project.configURL, encoding: .utf8)
        text = text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("model = ") && $0 != "[agents.run]" }.joined(separator: "\n")
        if let model { text += "\n[agents.run]\nmodel = \"\(model)\"\n" }
        try text.write(to: fx.project.configURL, atomically: true, encoding: .utf8)
    }

    private func approvals(_ fx: RunnerFixture, _ id: String) throws -> [Event] {
        try fx.events(id).filter { $0.kind == .goalApproved }
    }

    @Test func aNewGoalIsTimeoutOnlyUnlessTheConfigSetsADefaultBudget() async throws {
        let plain = try await RunnerFixture()
        let text = try String(contentsOf: plain.project.configURL, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.hasPrefix("default_budget_usd") }
            .joined(separator: "\n")
        try text.write(to: plain.project.configURL, atomically: true, encoding: .utf8)
        let id = try await plain.service.newThread(name: "plain", base: "main")
        let goal = try GoalFile.parse(String(contentsOf: plain.project.goalURL(id), encoding: .utf8)).goal
        #expect(goal.spend == .timeoutOnly && goal.budgetUSD == nil)

        let capped = try await RunnerFixture()
        try String(contentsOf: capped.project.configURL, encoding: .utf8)
            .replacingOccurrences(of: "default_budget_usd = 1.00", with: "default_budget_usd = 2.5")
            .write(to: capped.project.configURL, atomically: true, encoding: .utf8)
        let cappedID = try await capped.service.newThread(name: "capped", base: "main")
        let cappedGoal = try GoalFile.parse(String(contentsOf: capped.project.goalURL(cappedID), encoding: .utf8)).goal
        #expect(cappedGoal.budgetUSD == Decimal(string: "2.5"))

        // A copied goal that says timeout_only keeps saying it, whatever the config's default.
        let other = try await RunnerFixture()
        let kept = try await other.service.newThread(name: "kept", base: "main", settings: GoalSettings(timeoutOnly: true))
        let keptGoal = try GoalFile.parse(String(contentsOf: other.project.goalURL(kept), encoding: .utf8)).goal
        #expect(keptGoal.spend == .timeoutOnly && keptGoal.budgetUSD == nil)
    }

    @Test func approveRecordsResolvedAgent() async throws {
        let fx = try await RunnerFixture(extraConfig: Self.runModel)
        let id = try await fx.approvedThread()
        let event = try #require(approvals(fx, id).last)
        #expect(event.data["provider"] == "claude" && event.data["model"] == "opus")
        #expect(ThreadStore(project: fx.project).state(of: id).approvedAgent == ApprovedAgent(provider: "claude", model: "opus"))
        #expect(LogFormatter.describe(event).hasSuffix("goal approved for coding on claude, opus"))
    }

    @Test func runRefusesChangedAgent() async throws {
        let fx = try await RunnerFixture(extraConfig: Self.runModel)
        let id = try await fx.approvedThread()
        try setModel("haiku", in: fx)
        let error = await #expect(throws: RunnerError.self) { _ = try await fx.runner(id).run(fx.options()) }
        #expect(error == .codingSettingsChanged(approved: "claude, opus", now: "claude, haiku"))
        #expect(error?.description.contains("workbench goal approve") == true)
        #expect(try fx.kinds(id).filter { $0 == "turn.started" }.isEmpty, "nothing ran")
    }

    @Test func reapproveAfterConfigChange() async throws {
        let fx = try await RunnerFixture(extraConfig: Self.runModel)
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

    @Test func approvalRecordsSpendPolicy() async throws {
        let fx = try await RunnerFixture()
        let other = try await RunnerFixture()
        let capped = try await other.approvedThread("capped")
        let cappedFx = other
        let event = try #require(approvals(cappedFx, capped).last)
        #expect(event.data["spend_policy"] == "hard_cap" && event.data["budget_usd"] != .null)
        let free = try await fx.timeoutOnlyThread("free")
        let freeEvent = try #require(approvals(fx, free).last)
        #expect(freeEvent.data["spend_policy"] == "timeout_only" && freeEvent.data["budget_usd"] == .null)
        let binding = try #require(ThreadStore(project: fx.project).state(of: free).approvedAgent)
        #expect(binding.spendPolicy == "timeout_only" && binding.description.hasSuffix("no dollar cap"))
        #expect(ThreadStore(project: fx.project).state(of: free).approvedFor?.description.contains("no dollar cap") == true)
    }

    @Test func changedSpendPolicyNeedsFreshApprove() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        // Dropping the cap in the goal is a goal edit: the approval is stale and nothing runs.
        let url = fx.project.goalURL(id)
        let text = try String(contentsOf: url, encoding: .utf8)
        try text.replacingOccurrences(
            of: #"budget_usd: [0-9.]+"#, with: "spend_policy: timeout_only", options: .regularExpression
        ).write(to: url, atomically: true, encoding: .utf8)
        let error = await #expect(throws: RunnerError.self) { _ = try await fx.runner(id).run(fx.options()) }
        #expect(error == .goalNotApproved(.stale))
        #expect(try fx.kinds(id).filter { $0 == "turn.started" }.isEmpty)
        // A fresh approve records the new policy and the run goes ahead.
        try await fx.service.approve(id: id)
        #expect(try approvals(fx, id).last?.data["spend_policy"] == "timeout_only")
        #expect(try await fx.runner(id).run(fx.options()).result == .succeeded)
    }

    @Test func anApprovalForADifferentSpendPolicyIsRefusedEvenWithTheSameHash() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        let state = ThreadStore(project: fx.project).state(of: id)
        let agent = ResolvedAgent(provider: .claude, model: nil, allowUnpriced: false)
        #expect(throws: RunnerError.self) {
            try ThreadRunner.requireApprovedAgent(state: state, agent: agent, spendPolicy: "timeout_only")
        }
        try ThreadRunner.requireApprovedAgent(state: state, agent: agent, spendPolicy: "hard_cap")
    }

    @Test func anApprovalForADifferentEffortIsRefused() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        let state = ThreadStore(project: fx.project).state(of: id)
        let now = ResolvedAgent(provider: .claude, model: nil, reasoningEffort: "high", allowUnpriced: false)
        #expect(throws: RunnerError.self) { try ThreadRunner.requireApprovedAgent(state: state, agent: now) }
        try ThreadRunner.requireApprovedAgent(
            state: state, agent: ResolvedAgent(provider: .claude, model: nil, allowUnpriced: false))
    }

    @Test func approveTwiceWritesOnce() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        try await fx.service.approve(id: id)
        #expect(try approvals(fx, id).count == 1)
    }

    @Test func anApprovalWithoutSpendPolicyReadsAsHardCap() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        let url = fx.project.eventsURL(id)
        let text = try String(contentsOf: url, encoding: .utf8)
            .replacingOccurrences(of: ",\"spend_policy\":\"hard_cap\"", with: "")
            .replacingOccurrences(of: "\"spend_policy\":\"hard_cap\",", with: "")
        try text.write(to: url, atomically: true, encoding: .utf8)
        let state = ThreadStore(project: fx.project).state(of: id)
        #expect(state.approvedAgent?.spendPolicy == "hard_cap")
        #expect(try await fx.runner(id).run(fx.options()).result == .succeeded)
    }

    @Test func legacyApprovalStillRuns() async throws {
        let fx = try await RunnerFixture(extraConfig: Self.runModel)
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
        #expect(chosen.sessionID == "22222222-2222-2222-2222-222222222222" && !chosen.confirmed, "unconfirmed: safe fallback")
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
