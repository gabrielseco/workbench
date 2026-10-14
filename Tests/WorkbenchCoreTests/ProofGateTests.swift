import Foundation
import Testing

@testable import WorkbenchCore

private func cli(_ arguments: [String], in fx: RunnerFixture) async throws -> (code: Int32?, text: String) {
    var spawn = SpawnRequest(
        executable: WorkbenchBinary.executable, arguments: arguments,
        environment: ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "USER": NSUserName(), "FAKE_CLAUDE": ""],
        workingDirectory: fx.repo, timeout: 120)
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

/// A draft thread whose proof names `command`, not yet approved.
private func draft(_ fx: RunnerFixture, proof command: String) async throws -> String {
    let id = try await fx.service.newThread(name: "work", base: "main")
    let url = fx.project.goalURL(id)
    var text = try String(contentsOf: url, encoding: .utf8)
    let fills = [
        ("TODO(workbench): say what should change, in a few sentences.", "Add a greeting to a.txt."),
        ("TODO(workbench): something that can be checked.", "a.txt contains the word hello."),
        ("TODO(workbench): how it will be shown (a test, a command, a screenshot).", "`\(command)` exits 0"),
        ("TODO(workbench): what must not change.", "Do not touch other files."),
    ]
    for (placeholder, value) in fills { text = text.replacingOccurrences(of: placeholder, with: value) }
    try text.write(to: url, atomically: true, encoding: .utf8)
    return id
}

@Suite struct ProofGateTests {
    @Test func approveRefusesAProofTheRunCannotExecuteAndApprovesNothing() async throws {
        let fx = try await RunnerFixture()
        let id = try await draft(fx, proof: "scripts/verify.sh --all")

        let result = try await cli(["goal", "approve"], in: fx)
        #expect(result.code == 6, "\(result.text)")
        #expect(result.text.contains("scripts/verify.sh --all") && result.text.contains("--allow-unrunnable-proofs"))
        #expect(result.text.contains("Bash(scripts/verify.sh --all:*)"), "names the entry that would permit it")
        let goal = try GoalFile.parse(String(contentsOf: fx.project.goalURL(id), encoding: .utf8))
        #expect(goal.goal.approval == .draft, "nothing was approved")
    }

    @Test func theFlagApprovesAndStillPrintsTheWarning() async throws {
        let fx = try await RunnerFixture()
        let id = try await draft(fx, proof: "scripts/verify.sh")
        let result = try await cli(["goal", "approve", "--allow-unrunnable-proofs"], in: fx)
        #expect(result.code == 0, "\(result.text)")
        #expect(result.text.contains("approved") && result.text.contains("warning:"))
        let goal = try GoalFile.parse(String(contentsOf: fx.project.goalURL(id), encoding: .utf8))
        #expect(goal.goal.approval == .approved)
    }

    @Test func aProofTheToolSetCanRunApprovesWithoutAnyWarning() async throws {
        let fx = try await RunnerFixture(extraConfig: "check_command = \"scripts/check.sh\"")
        _ = try await draft(fx, proof: "scripts/check.sh")
        let result = try await cli(["goal", "approve"], in: fx)
        #expect(result.code == 0, "\(result.text)")
        #expect(!result.text.contains("warning"))
    }

    @Test func runRefusesWhenTheConfigChangedAfterApprovalAndSpendsNothing() async throws {
        let fx = try await RunnerFixture()
        var config = try String(contentsOf: fx.project.configURL, encoding: .utf8)
        config = config.replacingOccurrences(
            of: "allowed = [\"Read\", \"Edit\"]", with: "allowed = [\"Read\", \"Edit\", \"Bash(scripts/verify.sh:*)\"]")
        try config.write(to: fx.project.configURL, atomically: true, encoding: .utf8)
        let id = try await draft(fx, proof: "scripts/verify.sh")
        _ = try await fx.service.approve(id: id)

        // The allowlist is tightened after approval; the goal's hash does not cover the config.
        try config.replacingOccurrences(of: ", \"Bash(scripts/verify.sh:*)\"", with: "")
            .write(to: fx.project.configURL, atomically: true, encoding: .utf8)

        do {
            _ = try await fx.runner(id).run(fx.options())
            Issue.record("expected a refusal")
        } catch let error as RunnerError {
            guard case .unrunnableProofs(let lines) = error else {
                Issue.record("unexpected \(error)")
                return
            }
            #expect(lines.contains("scripts/verify.sh"))
        }
        #expect(!(try fx.kinds(id)).contains("turn.started"), "no turn was started")
    }

    @Test func theRunnerFlagLetsItThrough() async throws {
        let fx = try await RunnerFixture()
        let id = try await draft(fx, proof: "scripts/verify.sh")
        _ = try await fx.service.approve(id: id)
        var options = fx.options()
        options.allowUnrunnableProofs = true
        let report = try await fx.runner(id).run(options)
        #expect(report.result == .succeeded)
    }

    @Test func aBrokenConfigStopsApprovalInsteadOfSkippingTheCheck() async throws {
        let fx = try await RunnerFixture()
        let id = try await draft(fx, proof: "scripts/verify.sh")
        try "this is = not valid [toml\n".write(to: fx.project.configURL, atomically: true, encoding: .utf8)

        let result = try await cli(["goal", "approve"], in: fx)
        #expect(result.code == 2, "\(result.text)")
        let goal = try GoalFile.parse(String(contentsOf: fx.project.goalURL(id), encoding: .utf8))
        #expect(goal.goal.approval == .draft, "nothing was approved")
    }

    @Test func runAndSendBackRefuseThroughTheCommandLineAndTheFlagIsWired() async throws {
        let fx = try await RunnerFixture()
        let id = try await draft(fx, proof: "scripts/verify.sh")
        _ = try await fx.service.approve(id: id)

        let refused = try await cli(["run"], in: fx)
        #expect(refused.code == 6, "\(refused.text)")
        #expect(refused.text.contains("scripts/verify.sh") && refused.text.contains("--allow-unrunnable-proofs"))
        #expect(!(try fx.kinds(id)).contains("turn.started"))

        let sent = try await cli(["send-back", "more"], in: fx)
        #expect(sent.code == 6, "\(sent.text)")

        let allowed = try await cli(["run", "--allow-unrunnable-proofs"], in: fx)
        #expect(allowed.code == 0, "\(allowed.text)")
        #expect(try fx.kinds(id).contains("turn.started"))
    }
}
