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
        #expect(found[0].resolved?.provider == .codex && found[0].note == "drafting is not enabled yet")
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
