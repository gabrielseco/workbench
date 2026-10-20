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

@Suite struct DoctorRunTests {
    private let table = "[run]\ncommand = \"scripts/app.sh\"\nready_line = \"ready\"\n"

    @Test func noRunMeansNothingToReport() async throws {
        let fx = try await RunnerFixture(extraConfig: "check_command = \"true\"")
        let report = try await Doctor(project: fx.project, git: fx.git).run(base: "main", options: options())
        #expect(report.run == nil)
    }

    @Test func aRunCommandInTheRepositoryIsReportedWithoutAProblem() async throws {
        let fx = try await RunnerFixture(extraConfig: "check_command = \"true\"\n" + table)
        let url = fx.repo.appendingPathComponent("scripts/app.sh")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: url, atomically: true, encoding: .utf8)
        _ = try await fx.git.run(["add", "-A"], in: fx.repo)
        _ = try await fx.git.run(["commit", "-q", "-m", "app"], in: fx.repo)
        let report = try await Doctor(project: fx.project, git: fx.git).run(base: "main", options: options())
        let run = try #require(report.run)
        #expect(run.config.command == "scripts/app.sh" && run.problem == nil)
    }

    @Test func aRunCommandMissingAtTheBaseIsAWarningThatKeepsDoctorPassing() async throws {
        let fx = try await RunnerFixture(extraConfig: "check_command = \"true\"\n" + table)
        let report = try await Doctor(project: fx.project, git: fx.git).run(base: "main", options: options())
        #expect(report.run?.problem?.contains("scripts/app.sh") == true)
        #expect(report.passed)
    }

    @Test func aRunWithTheVerifierOffSaysNothingUsesIt() async throws {
        let fx = try await RunnerFixture(extraConfig: "check_command = \"true\"\n" + table + "[verifier]\nenabled = false")
        let report = try await Doctor(project: fx.project, git: fx.git).run(base: "main", options: options())
        #expect(report.run?.problem?.contains("verifier, which is turned off") == true)
    }
}
