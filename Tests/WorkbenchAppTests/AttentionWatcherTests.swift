import AppKit
import Foundation
import Testing
import WorkbenchCore

@testable import WorkbenchApp

@MainActor @Suite struct AttentionSeenTests {
    private func failed(_ name: String, at seconds: TimeInterval) async throws -> TaskEntry {
        let (_, entries) = try await AttentionItemsTests.entries()
        let base = try #require(entries.first { $0.id == "weekly-report" })
        var entry = AttentionItemsTests.task(base, runs: [AttentionItemsTests.run(.failed, at: seconds)])
        entry.summary.name = name
        return entry
    }

    @Test func seenIsAPreferenceNotALog() async throws {
        let (fixture, _) = try await AttentionItemsTests.entries()
        let prefs = MemoryPreferences()
        let center = AttentionCenter(preferences: prefs)
        let a = try await failed("alpha", at: 100)
        await center.observe(project: "/p", projectName: "p", thread: nil, tasks: [a])
        #expect(center.items.count == 1)
        let logs = fixture.project.tasksDirectory
        func bytes() -> [String: Data] {
            var found: [String: Data] = [:]
            let items = FileManager.default.enumerator(at: logs, includingPropertiesForKeys: nil)
            while let url = items?.nextObject() as? URL { if let data = try? Data(contentsOf: url) { found[url.path] = data } }
            return found
        }
        let before = bytes()
        center.markSeen(shown: a)
        #expect(center.items.isEmpty)
        #expect(prefs.seenAttention.count == 1 && prefs.seenAttention[0].hasPrefix("/p|task:alpha:"))
        #expect(bytes() == before, "nothing is written to a task's log")
        // The mark outlives the centre (a relaunch), and a look at the same state stays quiet.
        let again = AttentionCenter(preferences: prefs)
        await again.observe(project: "/p", projectName: "p", thread: nil, tasks: [a])
        #expect(again.items.isEmpty)
    }

    @Test func aNewFailureIsNew() async throws {
        let prefs = MemoryPreferences()
        let center = AttentionCenter(preferences: prefs)
        let a = try await failed("alpha", at: 100)
        await center.observe(project: "/p", projectName: "p", thread: nil, tasks: [a])
        center.markSeen(shown: a)
        await center.observe(project: "/p", projectName: "p", thread: nil, tasks: [try await failed("alpha", at: 100)])
        #expect(center.items.isEmpty)
        await center.observe(project: "/p", projectName: "p", thread: nil, tasks: [try await failed("alpha", at: 900)])
        #expect(center.items.count == 1, "the same task failing again is a new reason")
    }

    @Test func onlyWhatIsShownIsSeen() async throws {
        // The watcher found a newer failure, but the screen still shows the older, good run: looking at it sees nothing.
        let center = AttentionCenter(preferences: MemoryPreferences())
        let (_, entries) = try await AttentionItemsTests.entries()
        let base = try #require(entries.first { $0.id == "weekly-report" })
        let good = AttentionItemsTests.task(base, runs: [AttentionItemsTests.run(.reported, at: 100)])
        let broken = AttentionItemsTests.task(base, runs: [AttentionItemsTests.run(.failed, at: 900)])
        await center.observe(project: "/p", projectName: "p", thread: nil, tasks: [good])
        await center.observe(project: "/p", projectName: "p", thread: nil, tasks: [broken])
        #expect(center.items.count == 1)
        center.markSeen(shown: good)
        #expect(center.items.count == 1, "the failure the screen has not shown is not seen")
        center.markSeen(shown: broken)
        #expect(center.items.isEmpty)
    }

    @Test func seenIsBounded() {
        let prefs = MemoryPreferences()
        let center = AttentionCenter(preferences: prefs)
        center.markSeen((0..<300).map { "task:t:\($0)" })
        #expect(prefs.seenAttention.count == AttentionCenter.seenLimit)
        #expect(prefs.seenAttention.last == "|task:t:299")
    }
}

@MainActor @Suite struct NotificationRouteTests {
    @Test func aNotificationForAnotherProjectIsNotActedOn() async throws {
        let (fixture, entries) = try await AttentionItemsTests.entries(git: true)
        let store = ProjectStore(preferences: MemoryPreferences())
        #expect(await store.open(fixture.project.root))
        await store.attention.observe(project: fixture.project.root.path, projectName: "p", thread: nil, tasks: entries)
        let before = store.attention.items.count
        store.show(.task("sync-fixtures"), project: "/somewhere/else")
        #expect(store.mode == .thread && store.tasks.selection == nil && store.attention.items.count == before)
        #expect(store.actionNote?.contains("not the project open now") == true)
        store.show(.task("sync-fixtures"), project: fixture.project.root.path)
        #expect(store.mode == .tasks && store.tasks.selection == "sync-fixtures")
    }

    @Test func aSelectionMadeBeforeTheFirstReadSurvivesIt() async throws {
        let (fixture, _) = try await AttentionItemsTests.entries(git: true)
        let store = ProjectStore(preferences: MemoryPreferences())
        #expect(await store.open(fixture.project.root))
        store.show(.task("update-docs"))
        await store.tasks.refresh(fixture.project)
        let shown = try #require(store.tasks.snapshot)
        #expect(store.tasks.selected(in: shown)?.id == "update-docs")
    }

    @Test func aSelectionForThisProjectSurvivesTheSwitchFromAnother() async throws {
        let (first, _) = try await AttentionItemsTests.entries(git: true)
        let (second, _) = try await AttentionItemsTests.entries(git: true)
        let store = ProjectStore(preferences: MemoryPreferences())
        #expect(await store.open(first.project.root))
        await store.tasks.refresh(first.project)
        #expect(await store.open(second.project.root))
        store.show(.task("update-docs"), project: second.project.root.path)
        await store.tasks.refresh(second.project)
        let shown = try #require(store.tasks.snapshot(for: second.project))
        #expect(store.tasks.selected(in: shown)?.id == "update-docs")
    }

    @Test func clickRoutes() async throws {
        #expect(AttentionRoute(encoded: AttentionRoute.thread("t1").encoded) == .thread("t1"))
        #expect(AttentionRoute(encoded: AttentionRoute.task("bump").encoded) == .task("bump"))
        #expect(AttentionRoute(encoded: "elsewhere:1") == nil)
        let (fixture, entries) = try await AttentionItemsTests.entries(git: true)
        let store = ProjectStore(preferences: MemoryPreferences())
        #expect(await store.open(fixture.project.root))
        await store.attention.observe(project: fixture.project.root.path, projectName: "p", thread: nil, tasks: entries)
        let before = store.attention.items.count
        #expect(before > 0)
        store.show(.task("sync-fixtures"))
        #expect(store.mode == .tasks && store.tasks.selection == "sync-fixtures")
        #expect(store.attention.items.count == before, "it is seen when the screen shows it, not when it is routed to")
        // Looking at the task as the screen shows it is what marks it seen.
        let shown = try #require(entries.first { $0.id == "sync-fixtures" })
        store.attention.markSeen(shown: shown)
        #expect(store.attention.items.count == before - 1)
        store.show(.thread("invoice-pagination"))
        #expect(store.mode == .thread)
    }
}

@MainActor @Suite struct AttentionWatcherTests {
    @Test func readsWithoutTimerProbes() async throws {
        let (fixture, entries) = try await AttentionItemsTests.entries()
        // The entries the menu bar watches are the Tasks screen's own, from the same core reads, with no timer service at all.
        let screen = try await TasksReader.core(environment: [
            "WORKBENCH_APP_HOME": fixture.root.appendingPathComponent("home").path,
            "WORKBENCH_APP_LAUNCHCTL": "/nonexistent/launchctl",
            "WORKBENCH_APP_PROBES": fixture.root.appendingPathComponent("none").path,
        ]).read(fixture.project, Date(timeIntervalSince1970: 1_793_500_000))
        #expect(screen.entries == entries)
    }

    @Test func pollsWhileTheWindowIsClosed() async throws {
        let (fixture, _) = try await AttentionItemsTests.entries(git: true)
        let store = ProjectStore(preferences: MemoryPreferences())
        #expect(await store.open(fixture.project.root))
        // The Tasks screen was never shown: nothing has read the tasks through it.
        #expect(store.mode == .thread && store.tasks.snapshot == nil)
        await store.observeAttention(readTasks: true)
        #expect(store.attention.items.contains { $0.route == .task("sync-fixtures") })
        #expect(store.tasks.snapshot == nil, "the watcher reads on its own and does not borrow the screen's model")
    }

    @Test func theAppComingToTheFrontIsALook() async throws {
        let center = AttentionCenter(preferences: MemoryPreferences())
        let looks = Counter()
        center.startPolling { looks.increment() }
        defer { center.stopPolling() }
        while looks.count < 1 { try await Task.sleep(for: .milliseconds(5)) }
        try await Task.sleep(for: .milliseconds(50))
        let before = looks.count
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        for _ in 0..<200 where looks.count == before { try await Task.sleep(for: .milliseconds(5)) }
        #expect(looks.count > before)
    }
}

@MainActor private final class Counter {
    private(set) var count = 0
    func increment() { count += 1 }
}
