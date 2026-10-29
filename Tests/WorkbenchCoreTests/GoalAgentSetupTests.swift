import Foundation
import Testing

@testable import WorkbenchCore

@Suite struct GoalAgentSetupTests {
    private static let tools = "\n[tools]\navailable = [\"Read\"]\nallowed = [\"Read\"]\n"

    private func project(config: String?) throws -> Project {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("goal-agent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".workbench"), withIntermediateDirectories: true)
        let project = Project(root: root)
        if let config { try config.write(to: project.configURL, atomically: true, encoding: .utf8) }
        return project
    }

    @Test func theTableIsAppendedAndTheRestOfTheConfigIsUntouched() throws {
        let original = "check_command = \"npm test\"\n" + Self.tools
        let project = try project(config: original)
        try GoalAgentSetup.enable(provider: .claude, in: project)
        let text = try String(contentsOf: project.configURL, encoding: .utf8)
        #expect(text == original + "\n[agents.goal]\nprovider = \"claude\"\n")
        #expect(try Config.load(from: project.configURL).resolvedGoalAgent?.provider == .claude)
    }

    @Test func aConfigWithoutAFinalNewlineStillGetsAWellFormedTable() throws {
        let bare = try project(config: "check_command = \"make\"\n" + Self.tools.trimmingCharacters(in: .newlines))
        try GoalAgentSetup.enable(provider: .codex, in: bare)
        let config = try Config.load(from: bare.configURL)
        #expect(config.resolvedGoalAgent?.provider == .codex && config.checkCommand == "make")
    }

    @Test func aProjectWithNoConfigIsToldToInitFirstAndNothingIsWritten() throws {
        let none = try project(config: nil)
        #expect(throws: GoalAgentSetup.Failure.noConfig) { try GoalAgentSetup.enable(provider: .claude, in: none) }
        #expect(!FileManager.default.fileExists(atPath: none.configURL.path))
    }

    @Test func anExistingTableIsNeverWrittenOver() throws {
        let original = "[agents.goal]\nmodel = \"opus\"\n"
        let project = try project(config: original)
        #expect(throws: GoalAgentSetup.Failure.alreadyThere) { try GoalAgentSetup.enable(provider: .claude, in: project) }
        #expect(try String(contentsOf: project.configURL, encoding: .utf8) == original)
    }

    @Test func aConfigThatDoesNotLoadIsLeftExactlyAsItWas() throws {
        let broken = "this is = = not toml\n"
        let project = try project(config: broken)
        #expect(throws: GoalAgentSetup.Failure.self) { try GoalAgentSetup.enable(provider: .claude, in: project) }
        #expect(try String(contentsOf: project.configURL, encoding: .utf8) == broken)
    }

    @Test func aProviderThatCannotDraftIsRefusedBeforeAnythingIsWritten() throws {
        let project = try project(config: nil)
        let other = try #require(AgentProviderID("gemini"))
        #expect(throws: GoalAgentSetup.Failure.unsupported("gemini")) { try GoalAgentSetup.enable(provider: other, in: project) }
        #expect(!FileManager.default.fileExists(atPath: project.configURL.path))
    }
}
