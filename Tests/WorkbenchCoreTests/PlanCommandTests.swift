import Foundation
import Testing

@testable import WorkbenchCore

private struct Out {
    var code: Int32?
    var stdout: [String]
    var stderr: String
    var text: String { (stdout + [stderr]).joined(separator: "\n") }
}

private func cli(_ arguments: [String], in fx: RunnerFixture) async throws -> Out {
    var spawn = SpawnRequest(
        executable: WorkbenchBinary.executable, arguments: arguments,
        environment: ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "USER": NSUserName()],
        workingDirectory: fx.repo, timeout: 120)
    spawn.snapshotInterval = 3600
    var lines: [String] = []
    var exit: ProcessExit?
    for await event in try ProcessRunner.start(spawn).events {
        if case .line(let line) = event { lines.append(line) }
        if case .exited(let e) = event { exit = e }
    }
    var code: Int32?
    if case .exited(let c)? = exit?.termination { code = c }
    return Out(code: code, stdout: lines, stderr: exit?.stderrTail ?? "")
}

@Suite(.processGate) struct PlanCommandTests {
    @Test func showAndEditThroughTheBinary() async throws {
        let fx = try await RunnerFixture()
        _ = try await fx.approvedThread()

        var out = try await cli(["plan", "show"], in: fx)
        #expect(out.code == 0 && out.text.contains("no plan for"), "\(out.text)")

        out = try await cli(["plan", "edit"], in: fx)
        #expect(out.code == 6 && out.text.contains("no plan to edit"), "\(out.text)")
        out = try await cli(["plan", "edit", "--apply"], in: fx)
        #expect(out.code == 6 && out.text.contains("no draft to apply"), "\(out.text)")
        out = try await cli(["plan", "edit", "--apply", "--from", "x.md"], in: fx)
        #expect(out.code == 2, "\(out.text)")
        out = try await cli(["plan", "edit", "--from", "/no/such/file.md"], in: fx)
        #expect(out.code == 6 && out.text.contains("could not be read"), "\(out.text)")

        let file = fx.repo.deletingLastPathComponent().appendingPathComponent("plan-\(UUID().uuidString).md")
        try "## Approach\n\nA hand-written plan.\n".write(to: file, atomically: true, encoding: .utf8)
        out = try await cli(["plan", "edit", "--from", file.path], in: fx)
        #expect(out.code == 0 && out.text.contains("plans/plan-1.md"), "\(out.text)")
        out = try await cli(["plan", "edit", "--from", file.path], in: fx)
        #expect(out.code == 6 && out.text.contains("same as the latest"), "\(out.text)")

        out = try await cli(["plan", "show"], in: fx)
        #expect(out.code == 0 && out.text.contains("plan:      edited") && out.text.contains("A hand-written plan."))

        out = try await cli(["status", "--json"], in: fx)
        let status = try #require(
            JSONSerialization.jsonObject(with: Data((out.stdout.first ?? "").utf8)) as? [String: Any])
        let plan = try #require(status["plan"] as? [String: Any])
        #expect(plan["source"] as? String == "edited" && plan["stale"] as? Bool == false)
        #expect(status["plan_cost_usd"] as? Double == 0)
        out = try await cli(["review", "--json"], in: fx)
        let review = try #require(
            JSONSerialization.jsonObject(with: Data((out.stdout.first ?? "").utf8)) as? [String: Any])
        #expect((review["plan"] as? [String: Any])?["ref"] as? String == "plans/plan-1.md")

        out = try await cli(["plan", "edit"], in: fx)
        #expect(out.code == 0 && out.text.contains("draft:") && out.text.contains("plan edit --apply"), "\(out.text)")
        out = try await cli(["status"], in: fx)
        #expect(out.text.contains("plan:      edited"), "\(out.text)")
    }
}
