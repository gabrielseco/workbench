import Foundation
import Testing
import WorkbenchCore

@testable import WorkbenchApp

@MainActor private var keptSwitchFixtures: [AppFixture] = []

/// P26 slice 5: the top bar's Inbox / Automations switch.
@MainActor @Suite struct SwitchTests {
    private func store(needsYou: Int = 0) async throws -> ProjectStore {
        let fixture = try await AppFixture()
        keptSwitchFixtures.append(fixture)
        for index in 0..<needsYou {
            try await fixture.addThread("n\(index)", approved: true)
            try fixture.turn("n\(index)", 1)
        }
        let store = ProjectStore(preferences: MemoryPreferences(projectPath: nil), actions: GoalActions())
        #expect(await store.open(fixture.root))
        await store.reload()
        return store
    }

    @Test func theInboxCountsWhatNeedsYouAndSaysSoInWords() async throws {
        let store = try await store(needsYou: 2)
        #expect(store.inboxNeedsYou == 2)
        let inbox = try #require(store.switchSegments().first { $0.id == ProjectStore.inboxSegment })
        #expect(inbox.title == "Inbox" && inbox.count == 2)
        #expect(inbox.accessibility == "Inbox, 2 need you", "the count is said, not only drawn")
        let quiet = try await self.store()
        let none = try #require(quiet.switchSegments().first { $0.id == ProjectStore.inboxSegment })
        #expect(none.accessibility == "Inbox", "nothing to say when nothing asks")
    }

    @Test func theSelectionIsTheWindowMode() async throws {
        let store = try await store()
        #expect(store.switchSelection == ProjectStore.inboxSegment)
        store.chooseSwitch(ProjectStore.automationsSegment)
        #expect(store.mode == .tasks && store.switchSelection == ProjectStore.automationsSegment)
        store.chooseSwitch(ProjectStore.inboxSegment)
        #expect(store.mode == .thread && store.switchSelection == ProjectStore.inboxSegment)
    }

    @Test func goingBackToTheInboxLeavesTheNewTaskScreen() async throws {
        let store = try await store()
        store.beginNewTask()
        #expect(store.mode == .tasks && store.tasks.isNewShown(in: store.project))
        store.chooseSwitch(ProjectStore.inboxSegment)
        #expect(store.mode == .thread && !store.tasks.isNewShown(in: store.project), "not left half open behind the threads")
    }

    @Test func theAutomationsCountIsUnknownUntilTheTasksAreRead() async throws {
        let store = try await store()
        #expect(store.automationCount == nil)
        let segment = try #require(store.switchSegments().first { $0.id == ProjectStore.automationsSegment })
        #expect(segment.count == nil && segment.accessibility == "Automations", "not zero: not read")
        await store.tasks.refreshIfDue(store.project, visible: true, force: true)
        #expect(store.automationCount == 0, "read, and there are none")
    }

    @Test func theInboxRailStepsAsideOnlyWhileTheAutomationsListIsOnScreen() async throws {
        let store = try await store()
        #expect(!store.automationsListShown, "the inbox is what is chosen")
        store.chooseSwitch(ProjectStore.automationsSegment)
        await store.tasks.refreshIfDue(store.project, visible: true, force: true)
        #expect(store.automationCount == 0 && !store.automationsListShown, "no automation: the empty page has no list")
        store.beginNewTask()
        #expect(!store.automationsListShown, "the New task screen has none either")
    }
}
