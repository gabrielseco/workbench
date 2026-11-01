import Foundation
import Testing
import WorkbenchCore

@testable import WorkbenchApp

@MainActor @Suite struct MenuBarLabelTests {
    private func item(_ tone: TaskTone, _ id: String) -> AttentionItem {
        AttentionItem(id: id, route: .task(id), title: id, reason: "r", tone: tone, at: nil)
    }

    @Test func countOnlyWhenAboveZero() {
        let none = MenuBarLabelModel.make(items: [])
        #expect(none == MenuBarLabelModel(total: 0, tone: nil))
        #expect(none.accessibility == "Workbench")
        let one = MenuBarLabelModel.make(items: [item(.needsYou, "a")])
        #expect(one.total == 1 && one.accessibility == "Workbench, 1 thing needs you")
        let two = MenuBarLabelModel.make(items: [item(.needsYou, "a"), item(.needsYou, "b")])
        #expect(two.accessibility == "Workbench, 2 things need you")
    }

    @Test func colourFollowsTheWorst() {
        #expect(MenuBarLabelModel.make(items: [item(.needsYou, "a")]).tone == .needsYou)
        #expect(MenuBarLabelModel.make(items: [item(.needsYou, "a"), item(.broken, "b")]).tone == .broken)
        #expect(MenuBarLabelModel.make(items: [item(.broken, "b")]).tone == .broken)
    }
}

@MainActor @Suite struct MenuBarPopoverModelTests {
    private func model(
        _ scenario: AppScenario, items: [AttentionItem] = [], denied: Bool = false, shown: Bool = false
    ) async throws -> MenuBarPopoverModel {
        let fixture = try await AppFixture()
        try await scenario.build(in: fixture)
        let loaded = ProjectLoader.load(project: fixture.project)
        return MenuBarPopoverModel.make(
            project: fixture.project, screen: loaded.screen, items: items, review: nil, denied: denied, deniedShown: shown)
    }

    private func thread(from scenario: AppScenario) async throws -> (AttentionItem, ProjectScreen) {
        let fixture = try await AppFixture()
        try await scenario.build(in: fixture)
        let screen = ProjectLoader.load(project: fixture.project).screen
        guard case .thread(let shown) = screen, case .needsYou(let reason) = shown.attention else { throw NotNeedsYou() }
        let item = AttentionItem(
            id: "thread:\(shown.id):\(reason.since)", route: .thread(shown.id), title: shown.title ?? shown.id,
            reason: reason.text, tone: .needsYou, at: nil)
        return (item, screen)
    }

    private struct NotNeedsYou: Error {}

    @Test func aThreadAndATaskAreRows() async throws {
        let (thread, screen) = try await thread(from: .needsYou)
        let task = AttentionItem(
            id: "task:bump:1", route: .task("bump"), title: "bump", reason: "failed: the check failed", tone: .broken,
            at: Date(timeIntervalSince1970: 100))
        let shown = MenuBarPopoverModel.make(
            project: Project(root: URL(fileURLWithPath: "/work/remote-flows")), screen: screen, items: [thread, task],
            review: nil, denied: false, deniedShown: false, now: Date(timeIntervalSince1970: 200))
        #expect(shown.project == "remote-flows" && shown.status == .needsYou(2))
        #expect(shown.rows.count == 2 && shown.rows[0].item.route.isThread)
        #expect(shown.rows[0].detail.hasPrefix("Review") && shown.rows[0].detail.contains(" · "))
        #expect(shown.rows[1].detail.hasPrefix("failed: the check failed · "))
        #expect(!shown.rows[1].canSendBack)
        #expect(shown.deniedNote == nil)
    }

    @Test func states() async throws {
        // Nothing needs you: said so, with the project's own one-line state, never a stale `Needs you`.
        let quiet = try await model(.accepted)
        #expect(quiet.rows.isEmpty)
        if case .nothing(let line) = quiet.status {
            #expect(!line.isEmpty)
        } else {
            Issue.record("expected nothing: \(quiet.status)")
        }
        // Working is not a request.
        let working = try await model(.running)
        if case .working = working.status {} else { Issue.record("expected working: \(working.status)") }
        // A log that cannot be read is broken, in the core's words.
        let corrupt = try await model(.corrupt)
        if case .broken(let why) = corrupt.status {
            #expect(why.hasPrefix("The log of "))
        } else {
            Issue.record("expected broken")
        }
        // No project, and a project being opened.
        let none = MenuBarPopoverModel.make(
            project: nil, screen: .noProject, items: [], review: nil, denied: false, deniedShown: false)
        #expect(none.status == .noProject && none.project == nil)
        let opening = MenuBarPopoverModel.make(
            project: nil, screen: .opening(path: "/work/x"), items: [], review: nil, denied: false, deniedShown: false)
        #expect(opening.status == .opening("x"))
        // The task read failed: the items are the centre's last good ones, so they still show.
        let (thread, screen) = try await thread(from: .needsYou)
        let kept = MenuBarPopoverModel.make(
            project: nil, screen: screen, items: [thread], review: nil, denied: false, deniedShown: false)
        #expect(kept.status == .needsYou(1))
    }

    @Test func deniedIsSaidOnce() async throws {
        let first = try await model(.accepted, denied: true, shown: false)
        #expect(first.deniedNote?.contains("System Settings") == true)
        let later = try await model(.accepted, denied: true, shown: true)
        #expect(later.deniedNote == nil)
        let fine = try await model(.accepted, denied: false)
        #expect(fine.deniedNote == nil)
    }
}

@MainActor @Suite struct MenuBarRouteTests {
    @Test func sendBackOpensTheCard() async throws {
        let fixture = try await AppFixture()
        try await AppScenario.needsYou.build(in: fixture)
        let store = ProjectStore(preferences: MemoryPreferences())
        #expect(await store.open(fixture.project.root))
        store.show(.thread("invoice-pagination"), project: fixture.project.root.path)
        (store.actionError, store.sendingBack) = (nil, true)
        #expect(store.mode == .thread && store.sendingBack)
    }

    @Test func pausingIsAPreferenceTheToggleRedraws() {
        let prefs = MemoryPreferences()
        let center = AttentionCenter(preferences: prefs)
        #expect(!center.paused)
        center.paused = true
        #expect(prefs.notificationsPaused)
        #expect(AttentionCenter(preferences: prefs).paused, "it is still paused after a relaunch")
    }
}
