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

    @Test func theArrowsStepOverTheSegmentsAndStopAtTheEnds() {
        let ids = [ProjectStore.inboxSegment, ProjectStore.automationsSegment]
        #expect(SegmentedSwitch.neighbour(of: ids[0], in: ids, left: false) == ids[1])
        #expect(SegmentedSwitch.neighbour(of: ids[1], in: ids, left: true) == ids[0])
        #expect(SegmentedSwitch.neighbour(of: ids[0], in: ids, left: true) == nil)
        #expect(SegmentedSwitch.neighbour(of: ids[1], in: ids, left: false) == nil)
        #expect(SegmentedSwitch.neighbour(of: "gone", in: ids, left: false) == nil)
    }

    @Test func aScreenOpeningUnderAnyListWithTheKeysDoesNotTakeTheCaret() async throws {
        let store = try await store()
        #expect(!store.listHasKeys)
        store.listFocused = true
        #expect(store.listHasKeys, "the thread or automations list")
        store.listFocused = false
        store.railFocused = true
        #expect(store.listHasKeys, "the project rail")
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

    /// A store on the `tasks` scenario (seven tasks, two of them broken), the tasks read.
    private func tasksStore() async throws -> ProjectStore {
        let fixture = try await AppFixture()
        keptSwitchFixtures.append(fixture)
        try await AppScenario.tasks.build(in: fixture)
        let store = ProjectStore(preferences: MemoryPreferences(projectPath: nil), actions: GoalActions())
        #expect(await store.open(fixture.root))
        await store.tasks.refreshIfDue(store.project, visible: true, force: true)
        return store
    }

    @Test func theAutomationsCountIsWhatFailedAndIsRedInWords() async throws {
        let quiet = try await store()
        #expect(quiet.automationsFailing == 0, "nothing read, nothing failed")
        let plain = try #require(quiet.switchSegments().first { $0.id == ProjectStore.automationsSegment })
        #expect(plain.accessibility == "Automations")
        let store = try await tasksStore()
        let failing = store.automationsFailing
        #expect(failing == 2, "broken-task and sync-fixtures")
        let segment = try #require(store.switchSegments().first { $0.id == ProjectStore.automationsSegment })
        #expect(segment.count == 2 && segment.accessibility == "Automations, 2 failed", "said in words, not only filled red")
    }

    @Test func theInboxRailStepsAsideOnlyWhileTheAutomationsListIsOnScreen() async throws {
        let empty = try await store()
        empty.chooseSwitch(ProjectStore.automationsSegment)
        await empty.tasks.refreshIfDue(empty.project, visible: true, force: true)
        #expect(!empty.automationsListShown, "no automation: the empty page has no list")
        empty.beginNewTask()
        #expect(!empty.automationsListShown, "the New task screen has none either")
        let store = try await tasksStore()
        #expect(!store.automationsListShown, "the inbox is what is chosen")
        store.chooseSwitch(ProjectStore.automationsSegment)
        #expect(store.automationsListShown, "tasks to list: the list is the rail's place")
    }

    @Test func theInboxOfAllProjectsBringsBackTheRailFromAutomations() async throws {
        let store = try await tasksStore()
        store.chooseSwitch(ProjectStore.automationsSegment)
        #expect(store.automationsListShown)
        await store.showAllProjects()
        #expect(store.allProjects && store.mode == .thread, "it is an inbox: the threads' side")
        #expect(!store.automationsListShown, "so the rail it is the list of is on screen")
    }

    @Test func theArrowKeysStepThroughTheAutomations() async throws {
        let store = try await tasksStore()
        let names = try #require(store.tasks.snapshot(for: store.project)).entries.map(\.id)
        #expect(names.count == 7)
        #expect(AutomationsList.neighbour(of: names[2], in: names, up: false) == names[3])
        #expect(AutomationsList.neighbour(of: names[2], in: names, up: true) == names[1])
        #expect(AutomationsList.neighbour(of: names[0], in: names, up: true) == nil)
        #expect(AutomationsList.neighbour(of: names[6], in: names, up: false) == nil)
        #expect(AutomationsList.neighbour(of: nil, in: names, up: false) == nil)
    }
}
