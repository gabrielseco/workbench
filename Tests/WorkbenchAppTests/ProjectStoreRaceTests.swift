import Foundation
import Testing

@testable import WorkbenchApp
@testable import WorkbenchCore

/// What the Codex reviews of the app shell found: a damaged log, a failed switch, and reads and doctor runs that finish for a
/// project that is no longer the open one.
@MainActor @Suite struct ProjectStoreRaceTests {
    private func store(_ remembered: String? = nil) -> (ProjectStore, MemoryPreferences) {
        let prefs = MemoryPreferences(projectPath: remembered)
        return (ProjectStore(preferences: prefs, intervals: (.milliseconds(20), .milliseconds(20))), prefs)
    }

    private func snapshot(_ store: ProjectStore) -> ThreadSnapshot? {
        if case .thread(let snapshot) = store.screen { snapshot } else { nil }
    }

    // MARK: Corruption and failed switches the second review found

    @Test func aLogWithADamagedLineShowsWhatItHasAndSaysSo() async throws {
        let fixture = try await AppFixture()
        try await fixture.addThread("t1", approved: true)
        try fixture.append("t1", .turnStarted, turn: 1, data: ["session_id": "s1"])
        let handle = try FileHandle(forWritingTo: fixture.project.eventsURL("t1"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{this was the turn.ended line\n".utf8))
        try handle.close()
        let (store, _) = store()
        await store.open(fixture.root)
        let shown = try #require(snapshot(store))
        #expect(shown.attention == .working, "the readable part still shows")
        #expect(shown.problems == ["line 4 is not a valid event"], "\(shown.problems)")
    }

    @Test func anIntactLogHasNoProblems() async throws {
        let fixture = try await AppFixture()
        try await fixture.addThread("t1", approved: true)
        let (store, _) = store()
        await store.open(fixture.root)
        #expect(snapshot(store)?.problems == [])
    }

    @Test func aFailedSwitchClosesTheOpenProjectAndItsPollCannotEraseTheError() async throws {
        let fixture = try await AppFixture()
        try await fixture.addThread("t1", approved: true)
        let elsewhere = try await AppFixture(git: false, workbench: false)
        let (store, prefs) = store()
        #expect(await store.open(fixture.root))
        let remembered = prefs.projectPath
        #expect(await store.open(elsewhere.root) == false)
        #expect(store.project == nil && store.doctor == .notRun)
        try fixture.append("t1", .turnStarted, turn: 1, data: ["session_id": "s1"])
        await store.refresh()
        #expect(store.screen == .notAGitRepository(path: elsewhere.root.path), "the old project's poll does not come back")
        #expect(prefs.projectPath == remembered, "a relaunch still restores the project that was open")
    }

    @Test func theFooterCanOpenTheLogOfAThreadAndOfACorruptOne() async throws {
        let fixture = try await AppFixture()
        try await fixture.addThread("t1", approved: true)
        let (store, _) = store()
        await store.open(fixture.root)
        #expect(store.logURL == fixture.project.eventsURL("t1"))
        try fixture.overwriteLog("t1", with: "not json\n")
        await store.refresh()
        guard case .logCorrupt = store.screen else {
            Issue.record("\(store.screen)")
            return
        }
        #expect(store.logURL == fixture.project.eventsURL("t1"), "the screen says to open it, so the footer must")
        let none = ProjectStore(preferences: MemoryPreferences())
        #expect(none.logURL == nil)
    }

    // MARK: Races the review found

    /// One thing a seam waits for and another thing releases, for holding a read or a doctor run half way.
    private final class Gate: @unchecked Sendable {
        private let semaphore = DispatchSemaphore(value: 0)
        private let entered = DispatchSemaphore(value: 0)
        func enter() { entered.signal() }
        func waitUntilEntered() async {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    self.entered.wait()
                    continuation.resume()
                }
            }
        }
        func wait() { semaphore.wait() }
        func release() { semaphore.signal() }
    }

    private func eventLine(seq: Int, kind: EventKind, turn: Int, data: JSONValue) throws -> Data {
        var line = try JSONEncoder().encode(
            Event(seq: seq, ts: "2026-10-28T11:00:00.000Z", turn: turn, kind: kind, data: data))
        line.append(UInt8(ascii: "\n"))
        return line
    }

    @Test func aWriteThatLandsDuringTheReadIsShownByTheNextPoll() async throws {
        let fixture = try await AppFixture()
        try await fixture.addThread("t1", approved: true)
        try fixture.append("t1", .turnStarted, turn: 1, data: ["session_id": "s1"])
        let url = fixture.project.eventsURL("t1")
        let ended = try eventLine(seq: 4, kind: .turnEnded, turn: 1, data: ["result": "succeeded", "cost_usd": 1.0])
        let once = Once()
        let store = ProjectStore(
            preferences: MemoryPreferences(), intervals: (.milliseconds(20), .milliseconds(20)),
            loader: { project in
                // The turn ends right after the log was read: the screen shows the turn still open.
                ProjectLoader.load(project: project) {
                    guard once.take(), let handle = try? FileHandle(forWritingTo: url) else { return }
                    defer { try? handle.close() }
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: ended)
                }
            })
        await store.open(fixture.root)
        #expect(snapshot(store)?.state.openTurn == 1, "the screen was read before the write")
        await store.refresh()
        #expect(snapshot(store)?.state.openTurn == nil && snapshot(store)?.spine[.run].mark == .done)
    }

    @Test func aReloadForAnEarlierProjectNeverReplacesTheNewOne() async throws {
        let first = try await AppFixture()
        try await first.addThread("first", approved: true)
        let second = try await AppFixture()
        try await second.addThread("second", approved: true)
        let firstRoot = first.project.root
        let held = Gate()
        let hold = HoldFlag()
        let store = ProjectStore(
            preferences: MemoryPreferences(), intervals: (.milliseconds(20), .milliseconds(20)),
            loader: { project in
                if project.root == firstRoot && hold.isOn {
                    held.enter()
                    held.wait()
                }
                return ProjectLoader.load(project: project)
            })
        await store.open(first.root)
        try first.append("first", .turnStarted, turn: 1, data: ["session_id": "s1"])
        hold.isOn = true
        let slow = Task { await store.refresh() }
        await held.waitUntilEntered()
        hold.isOn = false
        await store.open(second.root)
        #expect(snapshot(store)?.id == "second")
        held.release()
        await slow.value
        #expect(snapshot(store)?.id == "second" && store.project == second.project)
    }

    @Test func aDoctorRunForAnEarlierProjectNeverReportsUnderTheNewOne() async throws {
        let first = try await AppFixture()
        try await first.addThread("first")
        let second = try await AppFixture()
        try await second.addThread("second")
        let (stream, release) = AsyncStream<Void>.makeStream()
        let store = ProjectStore(
            preferences: MemoryPreferences(),
            doctorRunner: { _, _ in
                for await _ in stream { break }
                return .healthy(seconds: 0.1)
            })
        await store.open(first.root)
        let running = Task { await store.runDoctor() }
        for _ in 0..<200 where store.doctor != .running { try await Task.sleep(for: .milliseconds(10)) }
        #expect(store.doctor == .running)
        await store.open(second.root)
        #expect(store.doctor == .notRun)
        release.yield()
        await running.value
        #expect(store.doctor == .notRun, "the first project's answer is not the second's")
    }

    // MARK: Accept and Ship start on the click

    /// A click while Accept or Ship is still going starts nothing, the failure stays on screen, and the next click runs again.
    @Test func acceptAndShipPreventDuplicateOperations() async throws {
        struct Refused: Error, CustomStringConvertible { var description: String { "refused" } }
        let (reading, calls) = (Latch(), Calls())
        let plan = AcceptPlan(
            id: "t1", worktree: URL(fileURLWithPath: "/tmp/w"), branch: "workbench/t1", diff: .unavailable(reason: "x"),
            hasPendingChanges: true, commits: [], check: nil, openWork: false, snapshot: "s", defaultMessage: "m")
        let shipPlan = ShipPlan(
            id: "t1", worktree: URL(fileURLWithPath: "/tmp/w"), branch: "workbench/t1", remoteBranch: "workbench/t1",
            base: "origin/main", head: "abcdef1234567890", origin: "git@example.test:me/repo.git", remote: .absent,
            pullRequest: nil)
        let actions = GoalActions(
            acceptPlan: { _, _ in
                calls.add("plan")
                await reading.wait()
                return plan
            },
            accept: { _, _, _, _ in
                calls.add("accept")
                throw Refused()
            },
            shipPreview: { _, _ in
                calls.add("preview")
                await reading.wait()
                return ShipPreview(plan: shipPlan)
            },
            ship: { _, _, _ in
                calls.add("ship")
                throw Refused()
            })
        let fixture = try await AppFixture()
        try await fixture.addThread("t1", approved: true)
        try fixture.turn("t1", 1)
        let store = ProjectStore(preferences: MemoryPreferences(), actions: actions)
        #expect(await store.open(fixture.root))

        let accepting = Task { await store.accept() }
        for _ in 0..<200 where calls.log.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        await store.accept()
        await store.ship()
        #expect(calls.log == ["plan"], "the clicks while Accept is going started nothing")
        #expect(store.deciding && store.busy != nil)
        await reading.open()
        await accepting.value
        #expect(calls.log == ["plan", "accept"] && store.actionError == "refused" && !store.deciding)

        try fixture.decide("t1", "accepted")
        await store.reload()
        await reading.close()
        let shipping = Task { await store.ship() }
        for _ in 0..<200 where calls.log.count < 3 { try await Task.sleep(for: .milliseconds(10)) }
        await store.ship()
        await store.accept()
        #expect(calls.log == ["plan", "accept", "preview"], "the clicks while Ship is going started nothing")
        await reading.open()
        await shipping.value
        #expect(calls.log == ["plan", "accept", "preview", "ship"] && store.actionError == "refused")
        #expect(store.notice == nil && store.busy == nil && !store.deciding)

        await store.ship()
        #expect(calls.log.suffix(2) == ["preview", "ship"], "a click after a failure runs again")
    }
}

/// Holds the seams that wait on it until opened; closing it holds the next ones.
private actor Latch {
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
    func close() { opened = false }
}

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ item: String) { lock.withLock { items.append(item) } }
    var log: [String] { lock.withLock { items } }
}

private final class HoldFlag: @unchecked Sendable {
    var isOn = false
}

private final class Once: @unchecked Sendable {
    private var used = false
    func take() -> Bool {
        defer { used = true }
        return !used
    }
}
