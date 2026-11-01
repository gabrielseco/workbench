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
        center.markSeen(task: "alpha")
        #expect(center.items.isEmpty)
        #expect(prefs.seenAttention.count == 1 && prefs.seenAttention[0].hasPrefix("task:alpha:"))
        #expect(bytes() == before, "nothing is written to a task's log")
        // The mark outlives the centre (a relaunch), and a look at the same state stays quiet.
        let again = AttentionCenter(preferences: prefs)
        await again.observe(project: "/p", projectName: "p", thread: nil, tasks: [a])
        #expect(again.items.isEmpty)
    }

    @Test func aNewFailureIsNew() async throws {
        let prefs = MemoryPreferences()
        let center = AttentionCenter(preferences: prefs)
        await center.observe(project: "/p", projectName: "p", thread: nil, tasks: [try await failed("alpha", at: 100)])
        center.markSeen(task: "alpha")
        await center.observe(project: "/p", projectName: "p", thread: nil, tasks: [try await failed("alpha", at: 100)])
        #expect(center.items.isEmpty)
        await center.observe(project: "/p", projectName: "p", thread: nil, tasks: [try await failed("alpha", at: 900)])
        #expect(center.items.count == 1, "the same task failing again is a new reason")
    }

    @Test func seenIsBounded() {
        let prefs = MemoryPreferences()
        let center = AttentionCenter(preferences: prefs)
        center.markSeen((0..<300).map { "task:t:\($0)" })
        #expect(prefs.seenAttention.count == AttentionCenter.seenLimit)
        #expect(prefs.seenAttention.last == "task:t:299")
    }
}

@MainActor @Suite struct NotificationRouteTests {
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
        #expect(store.attention.items.count == before - 1, "opening a task from a notification marks it seen")
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
        // It is a polling loop that can be started and stopped, so a closed window keeps being watched.
        store.startAttentionPolling()
        store.attention.stopPolling()
    }
}
