import Foundation
import Testing

@testable import WorkbenchCore

private func cli(_ arguments: [String], in fx: RunnerFixture) async throws -> (code: Int32?, text: String) {
    var spawn = SpawnRequest(
        executable: WorkbenchBinary.executable, arguments: arguments,
        environment: ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "USER": NSUserName()],
        workingDirectory: fx.repo, timeout: 60)
    spawn.snapshotInterval = 3600
    let run = try ProcessRunner.start(spawn)
    var lines: [String] = []
    var exit: ProcessExit?
    for await event in run.events {
        if case .line(let line) = event { lines.append(line) }
        if case .exited(let e) = event { exit = e }
    }
    var code: Int32?
    if case .exited(let c)? = exit?.termination { code = c }
    return (code, (lines + [exit?.stderrTail ?? ""]).joined(separator: "\n"))
}

private let noCap = "no dollar cap: bounded by 30 min per turn"

@Suite(.processGate) struct SpendPolicyVisibilityTests {
    @Test func textOutputsSayNoDollarCap() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.timeoutOnlyThread()
        // `approve` on an unchanged goal says it is approved already; a draft one prints the spend line.
        var text = try String(contentsOf: fx.project.goalURL(id), encoding: .utf8)
        text = text.replacingOccurrences(of: "turn_timeout_min: 30", with: "turn_timeout_min: 30 ")
            .replacingOccurrences(of: "Add a greeting", with: "Add a greeting now")
        try text.write(to: fx.project.goalURL(id), atomically: true, encoding: .utf8)
        let approve = try await cli(["goal", "approve"], in: fx)
        #expect(approve.code == 0 && approve.text.contains(noCap) && !approve.text.contains("budget:"), "\(approve.text)")
        #expect(approve.text.contains("no dollar cap"), "the coding line says it too")

        let status = try await cli(["status"], in: fx)
        #expect(status.text.contains(noCap) && !status.text.contains("budget $"), "\(status.text)")
        let review = try await cli(["review"], in: fx)
        #expect(review.text.contains(noCap), "\(review.text)")
        let doctor = try await cli(["doctor"], in: fx)
        #expect(doctor.text.contains(noCap), "\(doctor.text)")
    }

    @Test func aGoalWithACapKeepsItsBudgetLine() async throws {
        let fx = try await RunnerFixture()
        _ = try await fx.approvedThread()
        let status = try await cli(["status"], in: fx)
        #expect(status.text.contains("budget $1/turn") && !status.text.contains("no dollar cap"), "\(status.text)")
    }

    @Test func jsonCarriesSpendPolicy() async throws {
        let fx = try await RunnerFixture()
        _ = try await fx.timeoutOnlyThread()
        let status = try await cli(["status", "--json"], in: fx)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(status.text.utf8)) as? [String: Any])
        let goal = try #require(object["goal"] as? [String: Any])
        #expect(goal["spend_policy"] as? String == "timeout_only" && goal["budget_usd"] is NSNull, "\(goal)")
        let review = try await cli(["review", "--json"], in: fx)
        let reviewObject = try #require(try JSONSerialization.jsonObject(with: Data(review.text.utf8)) as? [String: Any])
        #expect(reviewObject["spend_policy"] as? String == "timeout_only")
        let approved = try #require(reviewObject["approved_for"] as? [String: Any])
        #expect(approved["spend_policy"] as? String == "timeout_only")
    }

    @Test func unknownCostIsNotZero() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.timeoutOnlyThread()
        _ = try await fx.runner(id).run(fx.options("no-result"))
        let end = try #require(ended(try fx.events(id)).first)
        #expect(end.data["cost_usd"] == nil, "a turn that reported no cost records none, not 0")
        let state = ThreadStore(project: fx.project).state(of: id)
        #expect(state.costUnknown && state.knownCostUSD == nil)
        #expect(ReviewReport.costText(state) == "unknown")
        let status = try await cli(["status"], in: fx)
        #expect(status.text.contains("cost:      unknown") && !status.text.contains("$0.00"), "\(status.text)")
        let json = try await cli(["status", "--json"], in: fx)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.text.utf8)) as? [String: Any])
        #expect(object["cost_usd"] is NSNull, "\(object["cost_usd"] ?? "missing")")
        // A reported cost is still a number.
        let known = try await RunnerFixture()
        let other = try await known.timeoutOnlyThread()
        _ = try await known.runner(other).run(known.options())
        let knownState = ThreadStore(project: known.project).state(of: other)
        #expect(!knownState.costUnknown && (knownState.knownCostUSD ?? 0) > 0)
    }

    @Test func approvedForShowsSpendPolicy() async throws {
        let fx = try await RunnerFixture()
        _ = try await fx.timeoutOnlyThread()
        let status = try await cli(["status"], in: fx)
        #expect(status.text.contains("approved for:") && status.text.contains("no dollar cap"), "\(status.text)")
    }
}
