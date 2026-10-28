import Foundation
import Testing
import WorkbenchCore

@testable import WorkbenchApp

private actor Gate {
    private var opened = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func open() {
        opened = true
        waiting.forEach { $0.resume() }
        waiting = []
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    func add(_ key: String) { lock.withLock { counts[key, default: 0] += 1 } }
    func count(_ key: String) -> Int { lock.withLock { counts[key, default: 0] } }
}

@MainActor private var keptFixtures: [AppFixture] = []

@MainActor @Suite struct RunControllerTests {
    private func store(
        _ calls: Counter, gate: Gate, terminalHolds: Bool = false, thread: (AppFixture) async throws -> Void
    ) async throws -> ProjectStore {
        let fixture = try await AppFixture()
        try await thread(fixture)
        let actions = GoalActions(
            makeRun: { _, _, _ in
                calls.add("make")
                return RunHandle(run: { await gate.wait() }, stop: { calls.add("stop"); await gate.open() })
            },
            requestStop: { _, _ in calls.add("request"); return terminalHolds })
        let store = ProjectStore(preferences: MemoryPreferences(projectPath: nil), actions: actions)
        #expect(await store.open(fixture.root))
        // Its folder goes away with it, so the store would read a project that vanished: held for the rest of the run.
        keptFixtures.append(fixture)
        return store
    }

    private func interrupted(_ fixture: AppFixture) async throws {
        try await fixture.addThread("t1", approved: true)
        try fixture.turn("t1", 1, result: "interrupted")
    }

    @Test func aSecondRunIsRefusedWhileOneIsGoing() async throws {
        let (calls, gate) = (Counter(), Gate())
        let store = try await store(calls, gate: gate, thread: interrupted)
        await store.runAgain()
        #expect(store.runningHere)
        await store.runAgain()
        #expect(calls.count("make") == 1 && store.actionError == "A run is already going.")
        await gate.open()
        try await Task.sleep(for: .milliseconds(100))
        #expect(!store.runningHere)
    }

    @Test func stopReachesTheRunTheAppHolds() async throws {
        let (calls, gate) = (Counter(), Gate())
        let store = try await store(calls, gate: gate, thread: interrupted)
        await store.runAgain()
        await store.stopTurn()
        try await Task.sleep(for: .milliseconds(100))
        #expect(calls.count("stop") == 1 && calls.count("request") == 0 && !store.runningHere && !store.stopping)
    }

    @Test func stopReachesARunATerminalHolds() async throws {
        let (calls, gate) = (Counter(), Gate())
        let store = try await store(calls, gate: gate, terminalHolds: true, thread: interrupted)
        await store.stopTurn()
        #expect(calls.count("request") == 1 && calls.count("stop") == 0 && store.actionError == nil)
    }

    @Test func stopWithNothingRunningSaysSo() async throws {
        let (calls, gate) = (Counter(), Gate())
        let store = try await store(calls, gate: gate, thread: interrupted)
        await store.stopTurn()
        #expect(store.actionError == "Nothing is running this thread." && !store.stopping)
    }

    @Test func aTurnLeftOpenWithNoRunnerReadsOrphanedAndTheAppsOwnRunDoesNot() async throws {
        let (calls, gate) = (Counter(), Gate())
        let store = try await store(calls, gate: gate) { fixture in
            try await fixture.addThread("t1", approved: true)
            try fixture.append("t1", .turnStarted, turn: 1, data: ["session_id": "s1"])
        }
        guard case .thread(let before) = store.screen else {
            Issue.record("no thread")
            return
        }
        #expect(before.run?.phase == .orphaned)
        await store.runAgain()
        await store.refresh()
        guard case .thread(let during) = store.screen else {
            Issue.record("no thread")
            return
        }
        #expect(during.run?.phase == .working)
        await gate.open()
    }

    @Test func aRunThatReturnsWithItsTurnStillOpenIsReported() async throws {
        let fixture = try await AppFixture()
        try await fixture.addThread("t1", approved: true)
        let actions = GoalActions(makeRun: { _, _, _ in
            RunHandle(
                run: { try? FileManager.default.removeItem(at: URL(fileURLWithPath: "/nonexistent")) }, stop: {})
        })
        let store = ProjectStore(preferences: MemoryPreferences(projectPath: nil), actions: actions)
        #expect(await store.open(fixture.root))
        try fixture.append("t1", .turnStarted, turn: 1, data: ["session_id": "s1"])
        await store.runAgain()
        try await Task.sleep(for: .milliseconds(200))
        #expect(store.actionError?.hasPrefix("The run ended without recording") == true)
        keptFixtures.append(fixture)
    }

    @Test func aRunThatCannotBeMadeIsReported() async throws {
        let fixture = try await AppFixture()
        try await interrupted(fixture)
        struct Missing: Error, CustomStringConvertible { var description: String { "no claude" } }
        let store = ProjectStore(
            preferences: MemoryPreferences(projectPath: nil), actions: GoalActions(makeRun: { _, _, _ in throw Missing() }))
        #expect(await store.open(fixture.root))
        await store.runAgain()
        #expect(store.actionError == "The run did not start: no claude" && !store.runningHere)
    }
}
