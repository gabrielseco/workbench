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

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var stops = 0
    var stopped: Int { lock.withLock { stops } }
    func stop() { lock.withLock { stops += 1 } }
}

@MainActor private var keptFixtures: [AppFixture] = []

@MainActor @Suite struct QuitWithARunTests {
    @Test func aGoalDraftIsWorkToo() async throws {
        #expect(QuitPrompt.work(threadRunIn: nil, taskRun: nil, drafting: true) == "a goal draft is still going.")
        #expect(
            QuitPrompt.work(threadRunIn: "p", taskRun: nil, drafting: true) == "a run in p and a goal draft are still going.")
        let fixture = try await AppFixture()
        keptFixtures.append(fixture)
        let release = Gate()
        let actions = GoalActions(
            draftGoal: { _, _, _, _, stop in
                stop.attach { Task { await release.open() } }
                await release.wait()
                return GoalDraftResult(id: nil, provider: .claude, failure: "stopped")
            })
        let store = ProjectStore(preferences: MemoryPreferences(projectPath: nil), actions: actions)
        #expect(await store.open(fixture.root))
        #expect(store.liveWork == nil)
        let drafting = Task { await store.draftGoal(request: "x") }
        while !store.drafting { try await Task.sleep(for: .milliseconds(10)) }
        #expect(store.liveWork == "a goal draft is still going.", "a draft alone is confirmed too")
        await store.stopWorkAndWait()
        #expect(!store.drafting)
        _ = await drafting.value
    }

    @Test func aStubbornDrafterDoesNotDelayStoppingTheRunNorExtendTheDeadline() async throws {
        let fixture = try await AppFixture()
        try await fixture.addThread("t1", approved: true)
        try fixture.turn("t1", 1, result: "interrupted")
        keptFixtures.append(fixture)
        let (calls, gate, never) = (Calls(), Gate(), Gate())
        let actions = GoalActions(
            makeRun: { _, _, _ in
                RunHandle(run: { await gate.wait() }, stop: { calls.stop(); await gate.open() })
            },
            draftGoal: { _, _, _, _, stop in
                stop.attach {}
                await never.wait()
                return GoalDraftResult(id: nil, provider: .claude, failure: "late")
            })
        let store = ProjectStore(preferences: MemoryPreferences(projectPath: nil), actions: actions)
        #expect(await store.open(fixture.root))
        let drafting = Task { await store.draftGoal(request: "x") }
        while !store.drafting { try await Task.sleep(for: .milliseconds(10)) }
        await store.runAgain()
        let began = ContinuousClock.now
        await store.stopWorkAndWait(timeout: .milliseconds(400))
        // The run was asked at once and ended; the drafter that never ends held the quit only to the one deadline.
        #expect(calls.stopped == 1 && store.runningProjectPath == nil)
        #expect(ContinuousClock.now - began < .seconds(3))
        await never.open()
        _ = await drafting.value
    }

    @Test func theQuitPromptSaysWhatItWouldEnd() {
        #expect(QuitPrompt.work(threadRunIn: nil, taskRun: nil) == nil)
        #expect(QuitPrompt.work(threadRunIn: "remote-flows", taskRun: nil) == "a run in remote-flows is still going.")
        #expect(QuitPrompt.work(threadRunIn: nil, taskRun: "bump") == "the task bump is still going.")
        #expect(
            QuitPrompt.work(threadRunIn: "remote-flows", taskRun: "bump")
                == "a run in remote-flows and the task bump are still going.")
    }

    private func storeWithARun(_ calls: Calls, gate: Gate, endsOnStop: Bool) async throws -> ProjectStore {
        let fixture = try await AppFixture()
        try await fixture.addThread("t1", approved: true)
        try fixture.turn("t1", 1, result: "interrupted")
        let actions = GoalActions(
            makeRun: { _, _, _ in
                RunHandle(
                    run: { await gate.wait() },
                    stop: {
                        calls.stop()
                        if endsOnStop { await gate.open() }
                    })
            })
        let store = ProjectStore(preferences: MemoryPreferences(projectPath: nil), actions: actions)
        #expect(await store.open(fixture.root))
        keptFixtures.append(fixture)
        return store
    }

    @Test func aQuitStopsTheRunTheAppHoldsAndWaitsForItToEnd() async throws {
        let (calls, gate) = (Calls(), Gate())
        let store = try await storeWithARun(calls, gate: gate, endsOnStop: true)
        #expect(store.liveWork == nil, "nothing is going: a quit just quits")
        await store.runAgain()
        #expect(store.liveWork?.hasSuffix("is still going.") == true && store.runningProjectPath != nil)
        await store.stopWorkAndWait()
        #expect(calls.stopped == 1 && store.runningProjectPath == nil && store.liveWork == nil)
    }

    @Test func aRunThatDoesNotEndIsWaitedForOnlyUntilTheDeadline() async throws {
        let (calls, gate) = (Calls(), Gate())
        let store = try await storeWithARun(calls, gate: gate, endsOnStop: false)
        await store.runAgain()
        let began = ContinuousClock.now
        await store.stopWorkAndWait(timeout: .milliseconds(200))
        #expect(ContinuousClock.now - began < .seconds(3))
        #expect(calls.stopped == 1 && store.runningProjectPath != nil, "it was asked to stop, and the quit does not hang on it")
        await gate.open()
    }

    @Test func aTaskRunStartedHereIsStoppedAndWaitedFor() async throws {
        let fixture = try await AppFixture(git: false)
        try await AppScenario.tasks.build(in: fixture)
        let switchSeen = Calls()
        let actions = TaskActions(
            inspect: TaskActions.core.inspect, approve: TaskActions.core.approve,
            run: { _, _, stop, _ in
                while !stop.isRequested { try? await Task.sleep(for: .milliseconds(10)) }
                switchSeen.stop()
                return TaskRunResult(outcome: .interrupted, reason: "stopped")
            })
        let tasks = TasksModel(actions: actions)
        await tasks.refresh(fixture.project)
        let entry = try #require(tasks.snapshot?.entries.first { $0.id == "weekly-report" })
        let started = Task {
            await tasks.beginRun(fixture.project, entry, threadRunGoing: false)
            await tasks.confirmRun(fixture.project)
        }
        while tasks.runningTask == nil { try await Task.sleep(for: .milliseconds(5)) }
        await tasks.stopAndWait(timeout: .seconds(3))
        await started.value
        #expect(switchSeen.stopped == 1 && tasks.runningTask == nil)
        #expect(tasks.lastResult?.result.outcome == .interrupted)
    }
}
