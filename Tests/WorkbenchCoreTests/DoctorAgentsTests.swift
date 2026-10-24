import Foundation
import Testing

@testable import WorkbenchCore

@Suite(.processGate) struct DoctorAgentsTests {
    private func report(_ extraConfig: String) async throws -> DoctorReport {
        let fx = try await RunnerFixture(extraConfig: extraConfig)
        var options = Doctor.Options()
        options.environment = ["PATH": "/usr/bin:/bin", "HOME": fx.repo.path]
        options.screenRecordingGranted = { true }
        return try await Doctor(project: fx.project, git: fx.git).run(base: "main", options: options)
    }

    @Test func defaultsAreShownPerResponsibility() async throws {
        let found = try await report("").agents
        #expect(found.map(\.role) == [.goal, .run, .judge, .review])
        #expect(found[0].resolved == nil && found[0].note == "goal drafting stays manual")
        #expect(found[1].resolved?.provider == .claude && found[2].resolved?.provider == .claude)
        #expect(found[3].resolved?.provider == .codex)
    }

    @Test func aConfiguredSelectionIsShown() async throws {
        let found = try await report("[agents.judge]\nmodel = \"haiku\"\n[agents.goal]\nprovider = \"codex\"").agents
        #expect(found[2].resolved?.model == "haiku")
        #expect(found[0].resolved?.provider == .codex && found[0].note == nil)
    }

    @Test func goalAgentUnpricedNotAllowed() async throws {
        let refused = try await report("[agents.goal]\nprovider = \"codex\"")
        let problem = try #require(refused.agentProblems.first { $0.role == .goal && $0.kind == "unpriced_not_allowed" })
        #expect(problem.message.contains("allow_unpriced") && problem.message.contains("[agents.goal]"), "\(problem.message)")
        #expect(refused.agents[0].resolved?.provider == .codex, "the goal agent's provider is shown")
        let allowed = try await report("[agents.goal]\nprovider = \"codex\"\nallow_unpriced = true")
        #expect(!allowed.agentProblems.contains { $0.role == .goal && $0.kind == "unpriced_not_allowed" })
        let claude = try await report("[agents.goal]\nprovider = \"claude\"\nmodel = \"sonnet\"")
        #expect(!claude.agentProblems.contains { $0.kind == "unpriced_not_allowed" })
        #expect(claude.agents[0].resolved?.model == "sonnet")
    }

    @Test func runOnCodexIsExplained() async throws {
        let found = try await report("[agents.run]\nprovider = \"codex\"")
        let run = try #require(found.agents.first { $0.role == .run })
        #expect(run.resolved?.provider == .codex)
        let note = try #require(run.issues.first { $0.kind == "unconfined_reads" })
        #expect(note.severity == .note && note.message.contains("outside the worktree"), "\(note.message)")
        #expect(!found.agentProblems.contains { $0.role == .run && $0.kind == "policy_without_controls" })
        // Claude confines reads, so it says nothing of the kind.
        let claude = try await report("")
        #expect(!claude.agents.flatMap(\.issues).contains { $0.role == .run && $0.kind == "unconfined_reads" })
    }

    @Test func theCommandPrintsOneLineEach() async throws {
        let fx = try await RunnerFixture(extraConfig: "model = \"opus\"\n[agents.judge]\nmodel = \"haiku\"")
        let ran = try await workbenchCLI(
            ["doctor"], in: fx.repo, environment: ["PATH": "/usr/bin:/bin", "HOME": fx.repo.path, "USER": NSUserName()])
        #expect(ran.code == 0, "\(ran.stderr)")
        let lines = ran.stdout.split(separator: "\n").map(String.init)
        #expect(lines.contains { $0.hasPrefix("agent goal:") && $0.contains("none") })
        #expect(lines.contains { $0.hasPrefix("agent run:") && $0.contains("claude, model opus") })
        #expect(lines.contains { $0.hasPrefix("agent judge:") && $0.contains("claude, model haiku") })
        #expect(lines.contains { $0.hasPrefix("agent review:") && $0.contains("codex, model the provider's default") })
    }
}
