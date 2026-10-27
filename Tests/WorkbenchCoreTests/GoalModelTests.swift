import Foundation
import Testing

@testable import WorkbenchCore

private let goalText = """
    ---
    id: g-2026-10-14-model
    title: Pick a model
    base: main
    budget_usd: 5.00
    turn_timeout_min: 30
    MODEL
    ---

    ## Request

    Do the thing.

    ## Criteria

    - [c1] The thing is done.
      - proof: cat thing

    ## Out of scope

    - Everything else.
    """

private func goal(model: String?) -> String {
    goalText.replacingOccurrences(of: "MODEL\n", with: model.map { "model: \($0)\n" } ?? "")
}

private func problems(in text: String) -> [GoalProblem] {
    do { _ = try GoalFile.parse(text) } catch let error as GoalParseError { return error.problems } catch {}
    return []
}

@Suite(.processGate) struct GoalModelParsingTests {
    @Test func theModelIsReadAndIsOptional() throws {
        #expect(try GoalFile.parse(goal(model: "opus")).goal.model == "opus")
        #expect(try GoalFile.parse(goal(model: "claude-opus-5-5")).goal.model == "claude-opus-5-5")
        #expect(try GoalFile.parse(goal(model: nil)).goal.model == nil)
    }

    @Test func anUnsafeModelIsRejectedWithItsLine() {
        for bad in ["--dangerous", "two words", "a;b", "$(x)"] {
            let found = problems(in: goal(model: bad))
            #expect(
                found.contains { $0.code == .invalidValue && $0.line == 7 && $0.message.contains("'model'") },
                "\(bad)")
        }
    }

    @Test func aDuplicateModelKeyIsAnError() {
        let text = goal(model: "opus").replacingOccurrences(of: "model: opus\n", with: "model: opus\nmodel: haiku\n")
        #expect(problems(in: text).contains { $0.code == .duplicateKey })
    }
}

@Suite(.processGate) struct GoalModelApprovalTests {
    private func legacyHash(body: String) -> String {
        let canonical = [
            "workbench-goal-v1", "base=main", "budget_usd=5", "turn_timeout_min=30", "---",
            GoalHash.canonicalBody(body),
        ].joined(separator: "\n")
        return referenceSHA256(Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    @Test func aGoalWithoutAModelKeepsTheHashItWasApprovedWith() throws {
        let file = try GoalFile.parse(goal(model: nil))
        let body = file.text.components(separatedBy: "\n---\n").dropFirst().joined(separator: "\n---\n")
        #expect(file.goal.contentHash == legacyHash(body: "\n" + body))
    }

    @Test func theModelIsPartOfWhatApprovalBinds() throws {
        let approved = try GoalFile.parse(goal(model: "opus")).approving()
        #expect(approved.goal.approval == .approved)
        #expect(approved.goal.model == "opus")

        let swapped = approved.text.replacingOccurrences(of: "model: opus", with: "model: haiku")
        #expect(try GoalFile.parse(swapped).goal.approval == .stale)
        let removed = approved.text.replacingOccurrences(of: "model: opus\n", with: "")
        #expect(try GoalFile.parse(removed).goal.approval == .stale)
        #expect(try GoalFile.parse(goal(model: "opus")).goal.contentHash
            != GoalFile.parse(goal(model: nil)).goal.contentHash)
    }
}

@Suite(.processGate) struct GoalModelInvocationTests {
    private func argv(config: String, goalModel: String?) async throws -> [String] {
        let fx = try await RunnerFixture(extraConfig: config)
        let id = try await fx.approvedThread()
        if let goalModel {
            let url = fx.project.goalURL(id)
            var text = try String(contentsOf: url, encoding: .utf8)
            text = text.replacingOccurrences(of: "turn_timeout_min: 30\n", with: "turn_timeout_min: 30\nmodel: \(goalModel)\n")
            try text.write(to: url, atomically: true, encoding: .utf8)
            _ = try await fx.service.approve(id: id)
        }
        _ = try await fx.runner(id).run(fx.options())
        let started = try #require(try fx.events(id).first { $0.kind == .turnStarted })
        guard case .array(let items)? = started.data["argv"] else {
            Issue.record("argv missing")
            return []
        }
        return items.compactMap(\.stringValue)
    }

    private func model(in argv: [String]) -> String? {
        argv.firstIndex(of: "--model").flatMap { argv.indices.contains($0 + 1) ? argv[$0 + 1] : nil }
    }

    @Test func theGoalsModelWinsOverTheConfigsThenTheConfigsThenTheCliDefault() async throws {
        let run = "[agents.run]\nmodel = \"sonnet\""
        #expect(model(in: try await argv(config: run, goalModel: "opus")) == "opus")
        #expect(model(in: try await argv(config: run, goalModel: nil)) == "sonnet")
        #expect(model(in: try await argv(config: "", goalModel: "opus")) == "opus")
        #expect(model(in: try await argv(config: "", goalModel: nil)) == nil)
    }

    @Test func aSendBackKeepsTheGoalsModel() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        let url = fx.project.goalURL(id)
        var text = try String(contentsOf: url, encoding: .utf8)
        text = text.replacingOccurrences(of: "turn_timeout_min: 30\n", with: "turn_timeout_min: 30\nmodel: opus\n")
        try text.write(to: url, atomically: true, encoding: .utf8)
        _ = try await fx.service.approve(id: id)
        _ = try await fx.runner(id).run(fx.options())
        _ = try await fx.runner(id).run(fx.options(feedback: "more"))

        let starts = try fx.events(id).filter { $0.kind == .turnStarted }
        #expect(starts.count == 2)
        for event in starts {
            guard case .array(let items)? = event.data["argv"] else { continue }
            let args = items.compactMap(\.stringValue)
            #expect(model(in: args) == "opus")
        }
    }
}
