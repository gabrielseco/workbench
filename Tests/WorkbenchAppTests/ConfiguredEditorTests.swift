import Foundation
import Testing
import WorkbenchCore

@testable import WorkbenchApp

@MainActor @Suite struct ConfiguredEditorTests {
    private func environment(global: String?) throws -> [String: String] {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".workbench"), withIntermediateDirectories: true)
        if let global {
            try global.write(to: home.appendingPathComponent(".workbench/config.toml"), atomically: true, encoding: .utf8)
        }
        return ["HOME": home.path]
    }

    private static let tools = "[tools]\navailable = [\"Read\"]\nallowed = [\"Read\"]\n"
    private let globalCode = "editor = \"code\"\n"

    private func project(config: String?) async throws -> AppFixture {
        let fixture = try await AppFixture()
        if let config {
            try FileManager.default.createDirectory(
                at: fixture.project.configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try config.write(to: fixture.project.configURL, atomically: true, encoding: .utf8)
        }
        return fixture
    }

    @Test func theProjectsEditorWinsOverTheGlobalOne() async throws {
        let fixture = try await project(config: "editor = \"zed\"\n" + Self.tools)
        let env = try environment(global: globalCode)
        let editor = GoalActions.configuredEditor(project: fixture.project, environment: env)
        #expect(editor == "zed")
    }

    @Test func withNoProjectEditorTheGlobalOneIsUsed() async throws {
        let fixture = try await project(config: nil)
        let env = try environment(global: globalCode)
        let editor = GoalActions.configuredEditor(project: fixture.project, environment: env)
        #expect(editor == "code")
    }

    @Test func aProjectConfigThatDoesNotLoadFallsBackToTheGlobalEditorInsteadOfFailing() async throws {
        let fixture = try await project(config: "model = \"opus\"\n")
        let env = try environment(global: globalCode)
        let editor = GoalActions.configuredEditor(project: fixture.project, environment: env)
        #expect(editor == "code")
    }

    @Test func withNeitherThereIsNoEditorAndNoGuess() async throws {
        let fixture = try await project(config: nil)
        let none = try environment(global: nil)
        #expect(GoalActions.configuredEditor(project: fixture.project, environment: none) == nil)
        let other = try environment(global: "projects_dir = \"~/x\"\n")
        #expect(GoalActions.configuredEditor(project: fixture.project, environment: other) == nil)
    }
}
