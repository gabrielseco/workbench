import Foundation
import Testing
import WorkbenchCore

@testable import WorkbenchApp

@MainActor private var keptFixtures: [AppFixture] = []

/// P26 slice 1: the Agents card is for a project by path, so the rail can open it for a project that is not the open one, and what
/// it edits is that project's config.
@MainActor @Suite struct AgentsPerProjectTests {
    private static let tools = "\n[tools]\navailable = [\"Read\"]\nallowed = [\"Read\"]\n"

    private func fixture(_ config: String = "") async throws -> AppFixture {
        let fixture = try await AppFixture()
        keptFixtures.append(fixture)
        try FileManager.default.createDirectory(
            at: fixture.project.configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (config + Self.tools).write(to: fixture.project.configURL, atomically: true, encoding: .utf8)
        return fixture
    }

    /// A store with `open` on screen and `other` known to it.
    private func store(open: AppFixture) async -> ProjectStore {
        let store = ProjectStore(preferences: MemoryPreferences(projectPath: nil))
        _ = await store.open(open.root)
        return store
    }

    @Test func theCardOpensForAnotherProjectAndShowsThatProjectsRoles() async throws {
        let open = try await fixture("[agents.run]\nmodel = \"sonnet\"")
        let other = try await fixture("[agents.run]\nmodel = \"opus\"")
        let store = await store(open: open)

        store.showAgents(for: other.project.root.path)
        await store.refreshCardAgents()
        #expect(store.agentsProject == other.project.root.path && store.showingAgents)
        #expect(store.cardAgentSetup?.row(.run)?.model == "opus", "the card shows the other project's role")
        await store.refreshAgentSetup()
        #expect(store.agentSetup?.row(.run)?.model == "sonnet", "the open project's own copy is not the card's")
    }

    @Test func anEditGoesToTheProjectTheCardIsForAndLeavesTheOpenOneAlone() async throws {
        let open = try await fixture("[agents.run]\nmodel = \"sonnet\"")
        let other = try await fixture("[agents.run]\nmodel = \"opus\"")
        let openBefore = try Data(contentsOf: open.project.configURL)
        let store = await store(open: open)
        store.showAgents(for: other.project.root.path)
        await store.refreshCardAgents()

        #expect(await store.setAgent(.run, .model, to: "haiku"))
        let written = try String(contentsOf: other.project.configURL, encoding: .utf8)
        #expect(written.contains("haiku") && !written.contains("opus"), "the other project's config changed: \(written)")
        #expect(try Data(contentsOf: open.project.configURL) == openBefore, "the open project's config did not")
        #expect(store.cardAgentSetup?.row(.run)?.model == "haiku", "the card reads what was written")
    }

    @Test func anEditToTheOpenProjectRefreshesTheCopyChatsAndTheNewGoalCardRead() async throws {
        let open = try await fixture("[agents.run]\nmodel = \"sonnet\"")
        let store = await store(open: open)
        await store.refreshAgentSetup()
        store.showAgents()
        await store.refreshCardAgents()
        #expect(store.agentsProject == open.project.root.path, "no path means the open project")

        #expect(await store.setAgent(.run, .model, to: "haiku"))
        #expect(store.agentSetup?.row(.run)?.model == "haiku", "the open project's own copy followed")
    }

    @Test func closingTheCardAndOpeningAnotherProjectBothPutItAway() async throws {
        let open = try await fixture()
        let other = try await fixture()
        let store = await store(open: open)
        store.showAgents()
        #expect(store.showingAgents)
        store.showingAgents = false
        #expect(store.agentsProject == nil)

        store.showAgents(for: other.project.root.path)
        #expect(await store.open(other.root))
        #expect(store.agentsProject == nil, "a card is for the project it was opened over")
    }

    @Test func openingTheCardFromTheProjectCardClosesTheProjectCard() async throws {
        let open = try await fixture()
        let store = await store(open: open)
        store.pickingProject = true
        store.showAgents(for: open.project.root.path)
        #expect(!store.pickingProject && store.showingAgents, "the card does not open under the picker")
    }
}
