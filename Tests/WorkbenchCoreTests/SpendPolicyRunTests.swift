import Foundation
import Testing

@testable import WorkbenchCore

extension RunnerFixture {
    /// A thread whose goal says `spend_policy: timeout_only` instead of a budget, approved.
    func timeoutOnlyThread(_ name: String = "free") async throws -> String {
        let id = try await service.newThread(name: name, base: "main")
        let url = project.goalURL(id)
        var text = try String(contentsOf: url, encoding: .utf8)
        let fills = [
            ("TODO(workbench): say what should change, in a few sentences.", "Add a greeting to a.txt."),
            ("TODO(workbench): something that can be checked.", "a.txt contains the word hello."),
            ("TODO(workbench): how it will be shown (a test, a command, a screenshot).", "cat a.txt"),
            ("TODO(workbench): what must not change.", "Do not touch other files."),
        ]
        for (placeholder, value) in fills { text = text.replacingOccurrences(of: placeholder, with: value) }
        text = text.replacingOccurrences(
            of: #"budget_usd: [0-9.]+"#, with: "spend_policy: timeout_only", options: .regularExpression)
        try text.write(to: url, atomically: true, encoding: .utf8)
        try await service.approve(id: id)
        return id
    }
}

private func codingRequest(spend: AgentSpend) -> AgentRequest {
    AgentRequest(
        provider: AgentProviderID("fake")!, prompt: "go", workingDirectory: URL(fileURLWithPath: "/tmp"),
        outputDirectory: URL(fileURLWithPath: "/tmp"), policy: .scopedCoding, spend: spend, purpose: .coding,
        environment: [:], limits: AgentLimits(timeout: 30))
}

@Suite struct SpendPolicyAdapterTests {
    @Test func hardCapGoalRefusedOnUncappedAdapter() {
        let provider = ScriptProvider(script: "echo DONE")
        let failure = codingRequest(spend: .hardCap(5)).validate(against: provider)
        #expect(failure?.kind == .unsupportedCapability)
        let message = failure?.message ?? ""
        #expect(message.contains("spend_policy: timeout_only") && message.contains("approve it again"), "\(message)")
        let request = codingRequest(spend: .hardCap(5))
        #expect(throws: AgentFailure.self) { _ = try AgentRunner.start(provider: provider, request: request) }
    }

    @Test(.processGate) func timeoutOnlyRunsOnUncappedAdapter() async throws {
        let provider = ScriptProvider(script: "echo DONE")
        #expect(codingRequest(spend: .timeoutOnly).validate(against: provider) == nil)
        let execution = try AgentRunner.start(provider: provider, request: codingRequest(spend: .timeoutOnly))
        for await _ in execution.activity {}
        #expect(await execution.completion.succeeded)
    }
}

@Suite(.processGate) struct SpendPolicyRunTests {
    private func argv(_ fx: RunnerFixture, _ id: String) throws -> [String] {
        let started = try #require(fx.events(id).first { $0.kind == .turnStarted })
        guard case .array(let items)? = started.data["argv"] else { return [] }
        return items.compactMap(\.stringValue)
    }

    @Test func claudeTimeoutOnlyOmitsMaxBudget() async throws {
        let fx = try await RunnerFixture()
        let free = try await fx.timeoutOnlyThread()
        let report = try await fx.runner(free).run(fx.options())
        #expect(report.result == .succeeded)
        #expect(try !argv(fx, free).contains("--max-budget-usd"))
    }

    @Test func hardCapGoalStillPassesMaxBudget() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        _ = try await fx.runner(id).run(fx.options())
        #expect(try argv(fx, id).contains("--max-budget-usd"))
    }

    @Test func claudeTimeoutOnlyRecordsCost() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.timeoutOnlyThread()
        _ = try await fx.runner(id).run(fx.options())
        let end = try #require(ended(try fx.events(id)).first)
        if case .double? = end.data["cost_usd"] {} else { Issue.record("no cost_usd: \(end.data)") }
        #expect(ThreadStore(project: fx.project).state(of: id).knownCostUSD != nil)
    }

    @Test func timeoutOnlyHungTurnStillEnds() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.timeoutOnlyThread()
        let report = try await fx.runner(id).run(fx.options("hang-after=1", timeout: 0.6))
        #expect(report.result == .timedOut)
        #expect(ended(try fx.events(id)).count == 1, "exactly one turn.ended")
        #expect(try fx.contents(id).isHealthy)
    }

    @Test func budgetOverrideRefusedForTimeoutOnly() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.timeoutOnlyThread()
        var options = fx.options()
        options.budgetOverride = 2
        let error = await #expect(throws: RunnerError.self) { _ = try await fx.runner(id).run(options) }
        #expect(error?.description.contains("no dollar cap") == true, "\(String(describing: error))")
        #expect(try fx.kinds(id).filter { $0 == "turn.started" }.isEmpty, "nothing ran")
    }
}
