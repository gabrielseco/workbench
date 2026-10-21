import Foundation
import Testing

@testable import WorkbenchCore

/// Doctor with no setup or check declared, so it only reads the config, and a HOME of its own.
private struct EditorDoctor {
    let fx: RunnerFixture
    let home: URL

    init(projectEditor: String? = nil, globalConfig: String? = nil) async throws {
        fx = try await RunnerFixture(extraConfig: projectEditor.map { "editor = \"\($0)\"" } ?? "")
        home = FileManager.default.temporaryDirectory.appendingPathComponent("wb-doctor-editor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        if let globalConfig {
            let dir = home.appendingPathComponent(".workbench")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try globalConfig.write(to: dir.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        }
    }

    func report(flag: String? = nil) async throws -> DoctorReport {
        var options = Doctor.Options()
        options.environment = ["PATH": "/usr/bin:/bin", "HOME": home.path]
        options.screenRecordingGranted = { true }
        options.editor = flag
        return try await Doctor(project: fx.project, git: fx.git).run(base: "main", options: options)
    }

    func cli(_ arguments: [String] = []) async throws -> CLIRan {
        try await workbenchCLI(
            ["doctor"] + arguments, in: fx.repo,
            environment: ["PATH": "/usr/bin:/bin", "HOME": home.path, "USER": NSUserName()])
    }
}

@Suite struct DoctorEditorTests {
    @Test func eachSourceIsReported() async throws {
        let both = try await EditorDoctor(projectEditor: "zed", globalConfig: "editor = \"subl\"\n")
        #expect(try await both.report(flag: "cursor").editor == EditorChoice(value: "cursor", source: .flag))
        #expect(try await both.report().editor == EditorChoice(value: "zed", source: .project))
        let global = try await EditorDoctor(globalConfig: "editor = \"subl -n\"\n")
        #expect(try await global.report().editor == EditorChoice(value: "subl -n", source: .global))
    }

    @Test func noneSetIsNilAndABrokenGlobalConfigIsOnlyANote() async throws {
        let none = try await EditorDoctor()
        let report = try await none.report()
        #expect(report.editor == nil && report.editorProblem == nil && report.passed)
        let broken = try await EditorDoctor(globalConfig: "editor = \"a && b\"\n")
        let noted = try await broken.report()
        #expect(noted.editor == nil && noted.editorProblem?.contains("'editor'") == true && noted.passed)
    }

    @Test func theDoctorLineSaysTheValueAndWhereItCameFromAndNeverFails() async throws {
        let project = try await EditorDoctor(projectEditor: "zed", globalConfig: "editor = \"subl\"\n")
        let fromProject = try await project.cli()
        #expect(fromProject.code == 0, "\(fromProject.stderr)")
        #expect(fromProject.stdout.split(separator: "\n").last == "editor:  zed (from project)", "\(fromProject.stdout)")
        let fromFlag = try await project.cli(["--editor", "cursor"])
        #expect(fromFlag.stdout.split(separator: "\n").last == "editor:  cursor (from --editor)")

        let global = try await EditorDoctor(globalConfig: "editor = \"subl\"\n")
        #expect(try await global.cli().stdout.split(separator: "\n").last == "editor:  subl (from global)")

        let none = try await EditorDoctor()
        let unset = try await none.cli()
        #expect(unset.code == 0 && unset.stdout.split(separator: "\n").last == "editor:  none set", "\(unset.stdout)")
    }
}
