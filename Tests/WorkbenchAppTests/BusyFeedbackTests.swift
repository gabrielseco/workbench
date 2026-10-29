import AppKit
import Foundation
import SwiftUI
import Testing

@testable import WorkbenchApp
@testable import WorkbenchCore

@MainActor private var keptBusyFixtures: [AppFixture] = []

/// A click is answered at once: while an action works, the store says what it is doing, and says nothing once it is done.
@MainActor @Suite struct BusyFeedbackTests {
    private func store(
        _ actions: GoalActions, approved: Bool = true, turn: Bool = true
    ) async throws -> (ProjectStore, AppFixture) {
        let fixture = try await AppFixture()
        keptBusyFixtures.append(fixture)
        try await fixture.addThread("t1", approved: approved)
        if turn { try fixture.turn("t1", 1) }
        let store = ProjectStore(preferences: MemoryPreferences(projectPath: nil), actions: actions)
        #expect(await store.open(fixture.root))
        return (store, fixture)
    }

    private func until(_ what: String, _ condition: () -> Bool) async throws {
        for _ in 0..<400 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
        #expect(condition(), "never: \(what)")
    }

    private nonisolated static let acceptPlan = AcceptPlan(
        id: "t1", worktree: URL(fileURLWithPath: "/tmp/w"), branch: "workbench/t1", diff: .unavailable(reason: "x"),
        hasPendingChanges: true, commits: [], check: nil, openWork: false, snapshot: "s", defaultMessage: "m")
    private nonisolated static let discardPlan = DiscardPlan(
        id: "t1", worktree: nil, branch: nil, diff: .unavailable(reason: "x"), commits: [])

    @Test func discardSaysWhatItIsDoingWhileItLooksAndAgainWhileItRemoves() async throws {
        let (looking, removing) = (Gate(), Gate())
        let actions = GoalActions(
            discardPlan: { _, _ in
                await looking.wait()
                return Self.discardPlan
            },
            discard: { _, _, _ in await removing.wait() })
        let (store, _) = try await store(actions)
        #expect(store.busy == nil)

        let preparing = Task { await store.prepareDiscard() }
        try await until("it says it is checking") { store.busy == "Checking what Discard would remove…" }
        looking.open()
        await preparing.value
        #expect(store.busy == nil && store.pendingDiscard != nil, "the confirmation is up and nothing is pending")

        let confirming = Task { await store.confirmDiscard() }
        try await until("it says it is discarding") { store.busy == "Discarding: removing the worktree and branch…" }
        #expect(store.pendingDiscard == nil, "the sheet is gone, so this line is all the person sees of the work")
        removing.open()
        await confirming.value
        #expect(store.busy == nil)
    }

    @Test func acceptSaysWhatItIsDoingWhileItLooksAndWhileItCommits() async throws {
        let (looking, committing) = (Gate(), Gate())
        let actions = GoalActions(
            acceptPlan: { _, _ in
                await looking.wait()
                return Self.acceptPlan
            },
            accept: { _, _, _, _ in
                await committing.wait()
                return AcceptResult(branch: "b", commit: "c", committedNow: true)
            })
        let (store, _) = try await store(actions)
        let preparing = Task { await store.prepareAccept() }
        try await until("it says it is checking") { store.busy == "Checking what Accept would do…" }
        looking.open()
        await preparing.value
        #expect(store.busy == nil)

        let confirming = Task { await store.confirmAccept(message: nil) }
        try await until("it says it is accepting") { store.busy == "Accepting: committing the work…" }
        committing.open()
        await confirming.value
        #expect(store.busy == nil && store.notice?.hasPrefix("Accepted") == true)
    }

    /// Draws the window (`ImageRenderer`, no display, not the live window) while an action is held half-way, for the pull request.
    private func renderWindow(_ name: String, _ store: ProjectStore) throws {
        let view = RootView(store: store).frame(width: 1100, height: 700).environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let image = try #require(renderer.cgImage, "\(name) did not render")
        let path = ProcessInfo.processInfo.environment["WORKBENCH_RENDER_DIR"]
        let folder = URL(fileURLWithPath: path ?? NSTemporaryDirectory()).appendingPathComponent("workbench-app-renders")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        try #require(png).write(to: folder.appendingPathComponent("\(name).png"))
    }

    @Test func theWindowShowsTheLineWhileTheWorkIsGoingOn() async throws {
        let (looking, removing, running) = (Gate(), Gate(), Gate())
        let actions = GoalActions(
            makeRun: { _, _, _ in RunHandle(run: { await running.wait() }, stop: {}) },
            discardPlan: { _, _ in
                await looking.wait()
                return Self.discardPlan
            },
            discard: { _, _, _ in await removing.wait() })
        let (store, _) = try await store(actions)
        let checking = Task { await store.prepareDiscard() }
        try await until("it is checking") { store.busy != nil }
        try renderWindow("busy-1-checking-discard", store)
        looking.open()
        await checking.value
        let discarding = Task { await store.confirmDiscard() }
        try await until("it is discarding") { store.busy == "Discarding: removing the worktree and branch…" }
        try renderWindow("busy-2-discarding", store)
        removing.open()
        await discarding.value

        let (starter, _) = try await self.store(actions, approved: true, turn: false)
        await starter.approveAndRun()
        #expect(starter.busy == "Starting the run…")
        try renderWindow("busy-3-starting-the-run", starter)
        running.open()
    }

    @Test func anActionThatFailsStopsSayingItIsWorking() async throws {
        struct Refused: Error, CustomStringConvertible { var description: String { "refused" } }
        let actions = GoalActions(acceptPlan: { _, _ in throw Refused() }, discardPlan: { _, _ in throw Refused() })
        let (store, _) = try await store(actions)
        await store.prepareAccept()
        #expect(store.busy == nil && store.actionError == "refused")
        await store.prepareDiscard()
        #expect(store.busy == nil)
    }

    @Test func runKeepsSayingItIsStartingUntilTheTurnShowsInTheLog() async throws {
        let (approving, running) = (Gate(), Gate())
        let actions = GoalActions(
            approve: { _, _ in await approving.wait() },
            makeRun: { _, _, _ in RunHandle(run: { await running.wait() }, stop: {}) })
        let (store, fixture) = try await store(actions, approved: false, turn: false)

        let clicked = Task { await store.approveAndRun() }
        try await until("it says it is approving") { store.busy == "Approving the goal…" }
        approving.open()
        await clicked.value
        #expect(store.busy == "Starting the run…", "approved, running, and no turn in the log yet")

        try fixture.append("t1", .turnStarted, turn: 1, data: ["session_id": "s1"])
        await store.refresh()
        #expect(store.busy == nil, "the turn is in the log: the screen itself shows the run now")
        running.open()
    }

    @Test func aRunThatEndsOrCannotStartStopsTheStartingLine() async throws {
        let ends = GoalActions(makeRun: { _, _, _ in RunHandle(run: {}, stop: {}) })
        let (store, _) = try await store(ends, approved: true, turn: false)
        await store.approveAndRun()
        try await until("the run ends and the line goes") { store.busy == nil }

        struct Cannot: Error, CustomStringConvertible { var description: String { "no claude" } }
        let fails = GoalActions(makeRun: { _, _, _ in throw Cannot() })
        let (other, _) = try await self.store(fails, approved: true, turn: false)
        await other.approveAndRun()
        #expect(other.busy == nil && other.actionError == "The run did not start: no claude")
    }

    @Test func aSecondTurnWaitsForANewerTurnNotTheOldOneStillOnScreen() async throws {
        let running = Gate()
        let actions = GoalActions(makeRun: { _, _, _ in RunHandle(run: { await running.wait() }, stop: {}) })
        let (store, fixture) = try await store(actions, approved: true, turn: true)
        await store.runAgain()
        #expect(store.busy == "Starting the run…", "turn 1 is already on screen, and it is not the one being waited for")
        await store.refresh()
        #expect(store.busy == "Starting the run…")
        try fixture.turn("t1", 2)
        await store.refresh()
        #expect(store.busy == nil, "turn 2 is in the log")
        running.open()
    }
}

private actor Gate {
    private var opened = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiting.append($0) }
    }
    nonisolated func open() { Task { await release() } }
    private func release() {
        opened = true
        waiting.forEach { $0.resume() }
        waiting = []
    }
}
