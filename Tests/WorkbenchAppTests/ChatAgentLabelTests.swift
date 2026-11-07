import Foundation
import SwiftUI
import Testing
import WorkbenchCore

@testable import WorkbenchApp

@MainActor private var keptAgentFixtures: [AppFixture] = []

/// The Agents card and the agent a chat names (docs/plan/P25-project-agents.md, slice 1): read from the project's config, never written.
@MainActor @Suite struct ChatAgentLabelTests {
    private func store(config: String?) async throws -> (ProjectStore, AppFixture) {
        let fixture = try await AppFixture()
        keptAgentFixtures.append(fixture)
        let tools = "\n[tools]\navailable = [\"Read\"]\nallowed = [\"Read\"]\n"
        try FileManager.default.createDirectory(
            at: fixture.project.configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ((config ?? "") + tools).write(to: fixture.project.configURL, atomically: true, encoding: .utf8)
        return (ProjectStore(preferences: MemoryPreferences(), project: fixture.project), fixture)
    }

    @Test func aChatNamesTheAgentTheConfigGivesTheGoalRole() async throws {
        let (store, _) = try await store(config: "[agents.goal]\nprovider = \"codex\"\nmodel = \"gpt-6.1-terra\"")
        #expect(store.agentSetup == nil, "nothing is read until a screen asks")
        await store.refreshAgentSetup()
        #expect(store.agentSetup?.row(.goal)?.label == "Codex · gpt-6.1-terra")
    }

    @Test func aChatFooterNamesTheAgentSaysNoneIsSetOrSaysNothingBeforeTheConfigIsRead() async throws {
        let (named, _) = try await store(config: "[agents.goal]\nprovider = \"codex\"\nmodel = \"gpt-6.1-terra\"")
        #expect(named.chatAgentNote == nil, "not read yet")
        await named.refreshAgentSetup()
        #expect(named.chatAgentNote == "Codex · gpt-6.1-terra")
        let (none, _) = try await store(config: nil)
        await none.refreshAgentSetup()
        #expect(none.chatAgentNote == "no goal agent is set, so replies are off")
    }

    @Test func aProjectWithNoConfigFileSaysNoGoalAgentInsteadOfCouldNotRead() async throws {
        let (store, fixture) = try await store(config: nil)
        try FileManager.default.removeItem(at: fixture.project.configURL)
        await store.refreshAgentSetup()
        #expect(store.agentSetup == nil && store.agentConfigMissing)
        #expect(store.chatAgentNote == "no goal agent is set, so replies are off")
        try "[tools]\navailable = [\"Read\"]\nallowed = [\"Read\"]\n".write(
            to: fixture.project.configURL, atomically: true, encoding: .utf8)
        await store.refreshAgentSetup()
        #expect(store.agentSetup != nil && !store.agentConfigMissing)
    }

    @Test func aProjectWithNoGoalAgentSaysSoInsteadOfNamingOne() async throws {
        let (store, _) = try await store(config: nil)
        await store.refreshAgentSetup()
        let goal = try #require(store.agentSetup?.row(.goal))
        #expect(goal.source == .off && goal.label == nil)
    }

    @Test func readingTheAgentsLeavesTheConfigAsItWas() async throws {
        let (store, fixture) = try await store(config: "[agents.run]\nmodel = \"opus\"")
        let before = try Data(contentsOf: fixture.project.configURL)
        await store.refreshAgentSetup()
        store.showingAgents = true
        store.showingAgents = false
        await store.refreshAgentSetup()
        #expect(try Data(contentsOf: fixture.project.configURL) == before)
    }

    @Test func changingTheConfigAndLookingAgainShowsTheNewSetting() async throws {
        let (store, fixture) = try await store(config: "[agents.goal]\nprovider = \"codex\"")
        await store.refreshAgentSetup()
        #expect(store.agentSetup?.row(.goal)?.provider == .codex)
        let text = try String(contentsOf: fixture.project.configURL, encoding: .utf8)
        try text.replacingOccurrences(of: "\"codex\"", with: "\"claude\"").write(
            to: fixture.project.configURL, atomically: true, encoding: .utf8)
        await store.refreshAgentSetup()
        #expect(store.agentSetup?.row(.goal)?.provider == .claude)
    }

    private func drawn(_ view: some View, height: CGFloat = 500) throws -> Data? {
        let framed = view.frame(width: 700, height: height).background(Color(nsColor: .windowBackgroundColor))
        let renderer = ImageRenderer(content: framed)
        renderer.scale = 1
        return try #require(renderer.cgImage).dataProvider?.data as Data?
    }

    @Test func theCardAndTheHeadingDrawWhatTheyAreGiven() async throws {
        let (store, _) = try await store(config: "[agents.goal]\nprovider = \"codex\"\nmodel = \"gpt-6.1-terra\"")
        await store.refreshAgentSetup()
        let withRows = try drawn(AgentsCard(store: store))
        let blank = try drawn(Color.clear)
        #expect(withRows != blank)
        let named = try drawn(NewThreadHeading(agent: .some("Codex · gpt-6.1-terra")))
        let off = try drawn(NewThreadHeading(agent: .some(nil)))
        let unknown = try drawn(NewThreadHeading(agent: nil))
        #expect(named != off && off != unknown && named != unknown, "named, off and not yet read each look different")
    }
}
