import Foundation
import Testing

@testable import WorkbenchCore

private func options() -> Doctor.Options {
    var o = Doctor.Options()
    o.environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "USER": NSUserName(), "FAKE_CLAUDE": "set"]
    o.setupTimeout = 30
    o.checkTimeout = 30
    o.screenRecordingGranted = { true }
    return o
}

private func commitSkill(_ fx: RunnerFixture, _ path: String, _ text: String) async throws {
    let url = fx.repo.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
    _ = try await fx.git.run(["add", path], in: fx.repo)
    _ = try await fx.git.run(["commit", "-q", "-m", "skill"], in: fx.repo)
}

@Suite(.processGate) struct DoctorVerifierTests {
    @Test func disabledMeansNothingToReport() async throws {
        let fx = try await RunnerFixture(extraConfig: "check_command = \"true\"\n[verifier]\nenabled = false")
        let report = try await Doctor(project: fx.project, git: fx.git).run(base: "main", options: options())
        #expect(report.verifier == nil)
    }

    @Test func theVerifierSkillIsReadAtTheBaseAndItsConfigReported() async throws {
        let path = ".claude/skills/verify/SKILL.md"
        let fx = try await RunnerFixture(
            extraConfig: """
                [agents.run]
                model = "opus"
                [verifier]
                skill = "\(path)"
                tools = ["Read", "Bash(scripts/snap.sh:*)"]
                """)
        try await commitSkill(fx, path, "# Verify\n\nDrive the app.\n")
        let report = try await Doctor(project: fx.project, git: fx.git).run(base: "main", options: options())

        let verifier = try #require(report.verifier)
        #expect(verifier.problem == nil)
        #expect(verifier.skill?.path == path)
        #expect(verifier.skill?.text == "# Verify\n\nDrive the app.")
        #expect(verifier.model == nil, "the coding model is not the fallback: the CLI default is")
        #expect(verifier.config.tools == ["Read", "Bash(scripts/snap.sh:*)"])
        #expect(report.passed)
    }

    @Test func aMissingSkillIsAWarningThatKeepsDoctorPassing() async throws {
        let fx = try await RunnerFixture(
            extraConfig: "check_command = \"true\"\n[verifier]\nskill = \".claude/skills/verify/SKILL.md\"\nmodel = \"sonnet\"")
        let report = try await Doctor(project: fx.project, git: fx.git).run(base: "main", options: options())

        let verifier = try #require(report.verifier)
        #expect(verifier.skill == nil)
        #expect(verifier.problem?.contains(".claude/skills/verify/SKILL.md") == true)
        #expect(verifier.model == "sonnet")
        #expect(report.passed && report.check.outcome == .passed)
    }

    @Test func aSkillEditedAfterTheBaseIsNotWhatDoctorReads() async throws {
        let path = "SKILL.md"
        let fx = try await RunnerFixture(extraConfig: "[verifier]\nskill = \"\(path)\"")
        try await commitSkill(fx, path, "committed\n")
        try "edited, not committed\n".write(
            to: fx.repo.appendingPathComponent(path), atomically: true, encoding: .utf8)
        let report = try await Doctor(project: fx.project, git: fx.git).run(base: "main", options: options())
        #expect(report.verifier?.skill?.text == "committed")
    }

    @Test func aSymlinkedSkillIsWarnedAboutWithTheRealPath() async throws {
        let fx = try await RunnerFixture(extraConfig: "[verifier]\nskill = \".claude/skills/verify/SKILL.md\"")
        try await commitSkill(fx, ".agents/skills/verify/SKILL.md", "real\n")
        let link = fx.repo.appendingPathComponent(".claude/skills/verify")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "../../.agents/skills/verify")
        _ = try await fx.git.run(["add", "-A"], in: fx.repo)
        _ = try await fx.git.run(["commit", "-q", "-m", "link"], in: fx.repo)
        let report = try await Doctor(project: fx.project, git: fx.git).run(base: "main", options: options())

        #expect(report.verifier?.skill == nil)
        #expect(report.verifier?.problem?.hasSuffix(": .agents/skills/verify/SKILL.md") == true)
    }
}

@Suite(.processGate) struct VerifierAvailabilityTests {
    @Test func theSkillIsAvailableOnlyWhenOnAndCommittedAtTheRef() async throws {
        let path = ".claude/skills/verify/SKILL.md"
        let fx = try await RunnerFixture()
        let config = try Config.load(from: fx.project.configURL)
        let before = await VerifierSkill.isAvailable(config: config, git: fx.git, repo: fx.repo, ref: "main")
        #expect(!before)
        try await commitSkill(fx, path, "# Verify\n")
        #expect(await VerifierSkill.isAvailable(config: config, git: fx.git, repo: fx.repo, ref: "main"))
        let off = try Config.parse("[verifier]\nenabled = false\n[tools]\navailable = [\"Read\"]\n")
        #expect(await !VerifierSkill.isAvailable(config: off, git: fx.git, repo: fx.repo, ref: "main"))
    }

    @Test func aDesktopAppWithoutScreenRecordingWarnsOnTheVerifier() async throws {
        let path = "SKILL.md"
        let fx = try await RunnerFixture(extraConfig: "app_type = \"desktop\"\n[verifier]\nskill = \"\(path)\"")
        try await commitSkill(fx, path, "drive it\n")
        var o = options()
        o.environment["TERM_PROGRAM"] = "iTerm.app"
        o.screenRecordingGranted = { false }
        let report = try await Doctor(project: fx.project, git: fx.git).run(base: "main", options: o)

        let warning = try #require(report.verifier?.screenRecording)
        #expect(warning.contains("Screen Recording") && warning.contains("iTerm.app") && warning.contains("Privacy & Security"))
        #expect(report.passed, "a warning, as the skill problem is")
    }

    @Test func theAppThatLaunchedWorkbenchIsNamedWhenThereIsNoTerminal() {
        #expect(Doctor.screenRecordingApp(environment: ["__CFBundleIdentifier": "dev.rogal.workbench"]) == "Workbench.app")
        #expect(Doctor.screenRecordingApp(environment: ["__CFBundleIdentifier": "com.apple.Terminal"]) == "com.apple.Terminal")
        #expect(
            Doctor.screenRecordingApp(environment: ["TERM_PROGRAM": "iTerm.app", "__CFBundleIdentifier": "com.googlecode.iterm2"])
                == "iTerm.app")
        #expect(Doctor.screenRecordingApp(environment: [:]).contains("terminal"))
    }

    @Test(arguments: ["app_type = \"desktop\"", "app_type = \"web\"", ""])
    func theGrantOrANonDesktopAppNeverWarns(extra: String) async throws {
        let path = "SKILL.md"
        let fx = try await RunnerFixture(extraConfig: "\(extra)\n[verifier]\nskill = \"\(path)\"")
        try await commitSkill(fx, path, "drive it\n")
        var o = options()
        // Granted, or never asked: the answer only matters for a desktop app.
        o.screenRecordingGranted = { extra.contains("desktop") }
        let report = try await Doctor(project: fx.project, git: fx.git).run(base: "main", options: o)
        #expect(report.verifier?.screenRecording == nil)
    }

    @Test func noSkillMeansNoScreenRecordingWarning() async throws {
        let fx = try await RunnerFixture(extraConfig: "app_type = \"desktop\"\n[verifier]\nskill = \"SKILL.md\"")
        var o = options()
        o.screenRecordingGranted = { false }
        let report = try await Doctor(project: fx.project, git: fx.git).run(base: "main", options: o)
        #expect(report.verifier?.screenRecording == nil && report.verifier?.problem != nil)
    }
}
