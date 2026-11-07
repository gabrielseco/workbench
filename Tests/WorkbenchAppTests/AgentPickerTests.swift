import Foundation
import SwiftUI
import Testing
import WorkbenchCore

@testable import WorkbenchApp

@MainActor private var keptPickerFixtures: [AppFixture] = []

/// The Agents card's pickers (docs/plan/P25-project-agents.md, slice 3): each edit is one `ConfigEdit` call on the project's config.
@MainActor @Suite struct AgentPickerTests {
    private static let tools = "\n[tools]\navailable = [\"Read\"]\nallowed = [\"Read\"]\n"

    private func store(config: String = "") async throws -> (ProjectStore, AppFixture) {
        let fixture = try await AppFixture()
        keptPickerFixtures.append(fixture)
        try FileManager.default.createDirectory(
            at: fixture.project.configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (config + Self.tools).write(to: fixture.project.configURL, atomically: true, encoding: .utf8)
        let store = ProjectStore(preferences: MemoryPreferences(), project: fixture.project)
        await store.refreshAgentSetup()
        return (store, fixture)
    }

    private func text(_ fixture: AppFixture) throws -> String {
        try String(contentsOf: fixture.project.configURL, encoding: .utf8)
    }

    @Test func writesOnlyThatKey() async throws {
        let original = "# mine\ncheck_command = \"make\"\n\n[agents.judge]\nmodel = \"sonnet\"\n"
        let (store, fixture) = try await store(config: original)
        await store.setAgent(.run, .model, to: "opus")
        #expect(try text(fixture) == original + Self.tools + "\n[agents.run]\nmodel = \"opus\"\n")
        #expect(store.agentSetup?.row(.run)?.model == "opus", "the card read the file again")
        await store.setAgent(.run, .reasoningEffort, to: "high")
        await store.setAgent(.run, .model, to: nil)
        #expect(try text(fixture).hasSuffix("[agents.run]\nreasoning_effort = \"high\"\n"))
        #expect(store.agentSetup?.row(.run)?.model == nil && store.agentSetup?.row(.run)?.reasoningEffort == "high")
        #expect(store.actionError == nil)
    }

    @Test func aRefusalIsSaidAndTheFileKeepsWhatItHad() async throws {
        let (store, fixture) = try await store(config: "[agents.run]\nmodel = \"opus\"\n")
        let before = try text(fixture)
        let written = await store.setAgent(.run, .model, to: "has a space")
        #expect(!written, "the caller is told, so the field goes back")
        #expect(store.actionError?.contains("cannot be set to that") == true, "\(String(describing: store.actionError))")
        #expect(try text(fixture) == before)
        #expect(store.agentSetup?.row(.run)?.model == "opus", "the picker is back on what the file has")
        await store.setAgent(.run, .model, to: "haiku")
        #expect(store.actionError == nil, "the next edit clears it")
    }

    @Test func goalOffAndOn() async throws {
        let (store, fixture) = try await store(
            config: "[agents.goal]\nprovider = \"codex\"\nmodel = \"gpt-6.1-terra\"\nreasoning_effort = \"medium\"\n")
        #expect(store.agentSetup?.row(.goal)?.label == "Codex · gpt-6.1-terra")
        await store.turnGoalAgentOff()
        #expect(store.actionError == nil, "\(String(describing: store.actionError))")
        #expect(store.agentSetup?.row(.goal)?.source == .off, "it still loads, with no goal agent")
        #expect(try !text(fixture).contains("agents.goal"))
        await store.setAgent(.goal, .provider, to: "claude")
        #expect(store.agentSetup?.row(.goal)?.label == "Claude · default model")
        await store.turnGoalAgentOff()
        await store.turnGoalAgentOff()
        #expect(store.actionError == nil, "off when already off is not an error")
    }

    @Test func noConfig() async throws {
        let (store, fixture) = try await store()
        try FileManager.default.removeItem(at: fixture.project.configURL)
        await store.refreshAgentSetup()
        #expect(store.agentConfigMissing)
        await store.setAgent(.run, .model, to: "opus")
        #expect(store.actionError?.contains("workbench init") == true, "\(String(describing: store.actionError))")
        #expect(!FileManager.default.fileExists(atPath: fixture.project.configURL.path), "nothing was created")
    }

    @Test func activeThreadNote() async throws {
        let (store, fixture) = try await store()
        await store.setAgent(.run, .model, to: "opus")
        #expect(store.actionNote == nil, "no thread, no note")
        try await fixture.addThread("g-2026-11-07-retry")
        await store.setAgent(.run, .model, to: "haiku")
        #expect(store.actionNote?.contains("g-2026-11-07-retry") == true && store.actionNote?.contains("goal approve") == true)
        await store.setAgent(.judge, .model, to: "haiku")
        #expect(store.actionNote == nil, "only the run agent is bound to an approval")
    }

    @Test func quickEditsAreNotLost() async throws {
        let (store, _) = try await store()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await store.setAgent(.run, .model, to: "opus") }
            group.addTask { await store.setAgent(.judge, .model, to: "sonnet") }
            group.addTask { await store.setAgent(.plan, .reasoningEffort, to: "high") }
            group.addTask { await store.setAgent(.ship, .model, to: "haiku") }
        }
        await store.refreshAgentSetup()
        let setup = try #require(store.agentSetup)
        #expect(setup.row(.run)?.model == "opus" && setup.row(.judge)?.model == "sonnet")
        #expect(setup.row(.plan)?.reasoningEffort == "high" && setup.row(.ship)?.model == "haiku")
    }

    @Test func theGoalAgentOffTakesItsWholeTableEvenWithKeysTheCardDoesNotShow() async throws {
        let (store, fixture) = try await store(
            config: "[agents.goal]\nprovider = \"codex\"\nmodel = \"gpt-5\"\nallow_unpriced = true\n")
        let off = await store.turnGoalAgentOff()
        #expect(off && store.actionError == nil, "\(String(describing: store.actionError))")
        #expect(store.agentSetup?.row(.goal)?.source == .off)
        #expect(try !text(fixture).contains("allow_unpriced"))
    }

    @Test func editsToTheSameKeyLandInTheOrderTheyWereMade() async throws {
        let (store, _) = try await store()
        let models = ["opus", "sonnet", "haiku", "opus", "sonnet", "haiku"]
        var tasks: [Task<Bool, Never>] = []
        for model in models { tasks.append(Task { await store.setAgent(.run, .model, to: model) }) }
        for task in tasks { _ = await task.value }
        #expect(store.agentSetup?.row(.run)?.model == "haiku", "the last choice wins")
    }

    @Test func aRowWhoseStageDecidesOnlyOneKeyStaysEditableForTheOthers() async throws {
        let stage = "[review]\nstages = [\"pr-review\"]\n[review.stage.pr-review]\nreasoning_effort = \"high\"\n"
        let (store, _) = try await store(config: stage)
        let row = try #require(store.agentSetup?.row(.review))
        #expect(row.lockedFields == [.reasoningEffort])
        await store.setAgent(.review, .model, to: "gpt-5")
        #expect(store.actionError == nil, "\(String(describing: store.actionError))")
        #expect(store.agentSetup?.row(.review)?.model == "gpt-5", "the model is still the card's to change")
    }

    @Test func aKeyAStageDecidesIsDrawnLockedAndNamesTheStage() async throws {
        let stage = "[review]\nstages = [\"pr-review\"]\n[review.stage.pr-review]\nprovider = \"codex\"\n"
        let (store, _) = try await store(config: stage)
        let row = try #require(store.agentSetup?.row(.review))
        #expect(row.lockedBy == "[review.stage.pr-review]" && row.lockedFields == [.provider])
        var free = row
        (free.lockedBy, free.lockedFields) = (nil, [])
        let edit = AgentEdit(set: { _, _, _ in true }, goalOff: { true })
        #expect(try drawn(AgentRow(row: row, edit: edit)) != drawn(AgentRow(row: free, edit: edit)), "locked and free differ")
    }

    @Test func aModelAStageDecidesIsDrawnLockedToo() async throws {
        let stage = "[review]\nstages = [\"pr-review\"]\n[review.stage.pr-review]\nmodel = \"gpt-6.1-sol\"\n"
            + "provider = \"codex\"\n"
        let (store, _) = try await store(config: stage)
        let row = try #require(store.agentSetup?.row(.review))
        #expect(row.lockedFields == [.provider, .model])
        var free = row
        (free.lockedBy, free.lockedFields) = (nil, [])
        let edit = AgentEdit(set: { _, _, _ in true }, goalOff: { true })
        #expect(try drawn(AgentRow(row: row, edit: edit)) != drawn(AgentRow(row: free, edit: edit)))
    }

    private func drawn(_ view: some View, height: CGFloat = 200) throws -> Data? {
        let framed = view.frame(width: 560, height: height).background(Color(nsColor: .windowBackgroundColor))
        let renderer = ImageRenderer(content: framed)
        renderer.scale = 1
        return try #require(renderer.cgImage).dataProvider?.data as Data?
    }

    @Test func aRowIsEditableOnlyWithEditAndWarnsOnAModelFromTheOtherProvider() async throws {
        let (store, _) = try await store(config: "[agents.run]\nprovider = \"codex\"\nmodel = \"opus\"\n")
        let row = try #require(store.agentSetup?.row(.run))
        let edit = AgentEdit(set: { _, _, _ in true }, goalOff: { true })
        let reading = try drawn(AgentRow(row: row))
        let editable = try drawn(AgentRow(row: row, edit: edit))
        #expect(reading != editable, "the pickers are drawn")
        var fine = row
        fine.model = "gpt-6.1-terra"
        let warned = try drawn(AgentRow(row: row, edit: edit))
        let quiet = try drawn(AgentRow(row: fine, edit: edit))
        #expect(warned != quiet, "a Claude name on Codex shows the warning and its button")
    }

    @Test func theMenuLinesMeanDefaultOtherOrAName() {
        #expect(AgentModelMenu.choice(for: AgentModelMenu.defaultTag) == .defaultModel)
        #expect(AgentModelMenu.choice(for: AgentModelMenu.otherTag) == .other)
        #expect(AgentModelMenu.choice(for: "opus") == .name("opus"))
        #expect(AgentModelMenu.selection(model: nil, other: false) == AgentModelMenu.defaultTag)
        #expect(AgentModelMenu.selection(model: "opus", other: false) == "opus")
        #expect(AgentModelMenu.selection(model: "opus", other: true) == AgentModelMenu.otherTag, "Other… while it is open")
        #expect(AgentModelMenu.options(["opus", "sonnet"], including: "my-ft") == ["opus", "sonnet", "my-ft"])
        #expect(AgentModelMenu.options(["opus", "sonnet"], including: "opus") == ["opus", "sonnet"])
        #expect(AgentModelMenu.options(["opus"], including: nil) == ["opus"])
    }

    @Test func menuFollowsTheProvider() async throws {
        let config = "[providers.codex]\nmodels = [\"gpt-extra\"]\n[agents.run]\nprovider = \"claude\"\n"
        let (store, _) = try await store(config: config)
        #expect(store.agentSetup?.row(.run)?.modelOptions == ModelCatalog.names(for: .claude))
        await store.setAgent(.run, .provider, to: "codex")
        #expect(store.agentSetup?.row(.run)?.modelOptions == ModelCatalog.names(for: .codex) + ["gpt-extra"])
        await store.setAgent(.run, .model, to: "opus")
        let row = try #require(store.agentSetup?.row(.run))
        #expect(row.modelOptions.contains("opus"), "a name the config has stays in the menu")
        #expect(AgentModelMenu.fitNote(provider: row.provider, model: row.model)?.contains("looks like a Claude model") == true)
        #expect(AgentModelMenu.fitNote(provider: .codex, model: "gpt-6.1-sol") == nil)
        #expect(AgentModelMenu.fitNote(provider: .claude, model: "opus") == nil)
        #expect(AgentModelMenu.fitNote(provider: nil, model: "opus") == nil)
    }
}
