import Foundation
import Testing
import WorkbenchCore

@testable import WorkbenchApp

@MainActor @Suite struct ProjectStoreTests {
    private func store(_ remembered: String? = nil) -> (ProjectStore, MemoryPreferences) {
        let prefs = MemoryPreferences(projectPath: remembered)
        return (ProjectStore(preferences: prefs, intervals: (.milliseconds(20), .milliseconds(20))), prefs)
    }

    private func snapshot(_ store: ProjectStore) -> ThreadSnapshot? {
        if case .thread(let snapshot) = store.screen { snapshot } else { nil }
    }

    // MARK: The unusable projects, each with what to do next

    @Test func startsWithNoProject() async {
        let (store, _) = store()
        await store.restore()
        #expect(store.screen == .noProject && store.screen.message != nil)
    }

    @Test func aFolderThatIsNotAGitRepositoryIsRefusedAndNotRemembered() async throws {
        let fixture = try await AppFixture(git: false, workbench: false)
        let (store, prefs) = store()
        #expect(await store.open(fixture.root) == false)
        #expect(store.screen == .notAGitRepository(path: fixture.root.path))
        #expect(prefs.projectPath == nil && store.project == nil)
        #expect(store.screen.message?.next.contains(fixture.root.path) == true)
    }

    @Test func aRepositoryWithoutWorkbenchSaysToInitAndIsRemembered() async throws {
        let fixture = try await AppFixture(workbench: false)
        let (store, prefs) = store()
        #expect(await store.open(fixture.root))
        #expect(store.screen == .workbenchMissing(path: fixture.project.root.path))
        #expect(prefs.projectPath == fixture.project.root.path)
        #expect(store.screen.message?.next.contains("workbench init") == true)
    }

    @Test func aProjectWithNoThreadSaysHowToStartOne() async throws {
        let fixture = try await AppFixture()
        let (store, _) = store()
        #expect(await store.open(fixture.root))
        #expect(store.screen == .noThread)
    }

    @Test func aLogWithNothingReadableIsCorruptAndNeverRewritten() async throws {
        let fixture = try await AppFixture()
        try await fixture.addThread("t1")
        let garbage = "not json\n{broken\n"
        try fixture.overwriteLog("t1", with: garbage)
        let (store, _) = store()
        #expect(await store.open(fixture.root))
        guard case .logCorrupt(let thread, let problems) = store.screen else {
            Issue.record("\(store.screen)")
            return
        }
        #expect(thread == "t1" && problems.first == "line 1 is not a valid event", "\(problems)")
        #expect(try String(contentsOf: fixture.project.eventsURL("t1"), encoding: .utf8) == garbage)
    }

    @Test func aMissingLogFileIsCorruptNotACrash() async throws {
        let fixture = try await AppFixture()
        try await fixture.addThread("t1")
        try FileManager.default.removeItem(at: fixture.project.eventsURL("t1"))
        let (store, _) = store()
        #expect(await store.open(fixture.root))
        guard case .logCorrupt(let thread, let problems) = store.screen else {
            Issue.record("\(store.screen)")
            return
        }
        #expect(thread == "t1" && problems.first?.hasPrefix("cannot read") == true, "\(problems)")
    }

    // MARK: Remembering the project

    @Test func theProjectIsRestoredOnRelaunch() async throws {
        let fixture = try await AppFixture()
        try await fixture.addThread("t1")
        let (first, prefs) = store()
        #expect(await first.open(fixture.root))
        let (second, _) = store(prefs.projectPath)
        await second.restore()
        #expect(snapshot(second)?.id == "t1" && second.project == first.project)
    }

    @Test func aRememberedPathThatWentAwayFallsBackToNoProject() async throws {
        let (store, prefs) = store("/nonexistent/workbench-test-\(UUID().uuidString)")
        await store.restore()
        #expect(store.screen == .noProject && prefs.projectPath == nil)
    }

    @Test func aSubfolderOpensItsRepositoryRoot() async throws {
        let fixture = try await AppFixture()
        let inner = fixture.root.appendingPathComponent("a/b")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        let (store, prefs) = store()
        #expect(await store.open(inner))
        #expect(store.project == fixture.project && prefs.projectPath == fixture.project.root.path)
    }

    // MARK: Deriving from the log

    @Test func aDraftThreadReadsAsWriting() async throws {
        let fixture = try await AppFixture()
        try await fixture.addThread("t1")
        let (store, _) = store()
        await store.open(fixture.root)
        let shown = try #require(snapshot(store))
        #expect(shown.spine[.goal].sublabel == "Writing" && shown.attention == .none)
        #expect(shown.stateText == "Draft · not approved" && shown.base == "main" && shown.title == "Thread t1")
    }

    @Test func anUnreportedCostReadsUnknownNeverZero() async throws {
        let fixture = try await AppFixture()
        try await fixture.addThread("t1", approved: true)
        try fixture.turn("t1", 1, cost: nil)
        let (store, _) = store()
        await store.open(fixture.root)
        #expect(snapshot(store)?.spendText == "unknown of $5.00")
    }

    @Test func aGrownLogUpdatesTheSpineAndTheSeq() async throws {
        let fixture = try await AppFixture()
        try await fixture.addThread("t1", approved: true)
        let (store, _) = store()
        await store.open(fixture.root)
        #expect(snapshot(store)?.spine[.run].sublabel == "Not started")
        try fixture.turn("t1", 1)
        await store.refresh()
        let shown = try #require(snapshot(store))
        #expect(shown.spine[.run].mark == .done && shown.lastSeq == 4)
        if case .needsYou = shown.attention {} else { Issue.record("a turn ended with no decision") }
    }

    @Test func anUnchangedLogIsNotReadAgain() async throws {
        let fixture = try await AppFixture()
        try await fixture.addThread("t1", approved: true)
        let (store, _) = store()
        await store.open(fixture.root)
        let url = fixture.project.eventsURL("t1")
        let before = (EventLogReadCount.reads(of: url), EventLogReadCount.bytes(of: url))
        for _ in 0..<5 { await store.refresh() }
        #expect(EventLogReadCount.reads(of: url) == before.0 && EventLogReadCount.bytes(of: url) == before.1)
    }

    @Test func aReplacedShorterLogIsReadFromTheStart() async throws {
        let fixture = try await AppFixture()
        try await fixture.addThread("t1", approved: true)
        try fixture.turn("t1", 1)
        try fixture.decide("t1", "accepted")
        let (store, _) = store()
        await store.open(fixture.root)
        #expect(snapshot(store)?.state.decision == "accepted")
        // `workbench compact` can replace a log with a shorter one.
        let kept = try String(contentsOf: fixture.project.eventsURL("t1"), encoding: .utf8)
            .split(separator: "\n").prefix(2).joined(separator: "\n") + "\n"
        try fixture.overwriteLog("t1", with: kept)
        await store.refresh()
        let shown = try #require(snapshot(store))
        #expect(shown.state.decision == nil && shown.lastSeq == 2)
    }

    @Test func aHalfWrittenLastLineIsIgnoredUntilItIsComplete() async throws {
        let fixture = try await AppFixture()
        try await fixture.addThread("t1", approved: true)
        let (store, _) = store()
        await store.open(fixture.root)
        let handle = try FileHandle(forWritingTo: fixture.project.eventsURL("t1"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"v":1,"seq":3,"ts":"2026-10-28T11:00:00.000Z","turn":1,"kind":"turn.sta"#.utf8))
        try handle.close()
        await store.refresh()
        #expect(snapshot(store)?.lastSeq == 2)
    }

    @Test func aThreadWrittenWhilePollingAppears() async throws {
        let fixture = try await AppFixture()
        let (store, _) = store()
        await store.open(fixture.root)
        #expect(store.screen == .noThread)
        store.startPolling()
        defer { store.stopPolling() }
        try await fixture.addThread("late", approved: true)
        try fixture.turn("late", 1)
        for _ in 0..<100 where snapshot(store) == nil { try await Task.sleep(for: .milliseconds(50)) }
        #expect(snapshot(store)?.id == "late")
    }

    // MARK: Which thread

    @Test func theActiveThreadWinsThenTheNewestThatIsNotCleaned() async throws {
        let fixture = try await AppFixture()
        try await fixture.addThread("old", approved: true)
        try fixture.turn("old", 1)
        try fixture.decide("old", "accepted")
        try fixture.ship("old")
        try fixture.append("old", .branchRemoved, data: ["reason": "merged"])
        try await fixture.addThread("shipped", approved: true)
        try fixture.turn("shipped", 1)
        try fixture.decide("shipped", "accepted")
        try fixture.ship("shipped", number: 8)
        let (store, _) = store()
        await store.open(fixture.root)
        #expect(snapshot(store)?.id == "shipped", "newest not cleaned, though it has ended")
        try await fixture.addThread("active")
        await store.refresh()
        #expect(snapshot(store)?.id == "active")
    }

    @Test func ifEveryThreadIsCleanedTheNewestIsShown() async throws {
        let fixture = try await AppFixture()
        try await fixture.addThread("only", approved: true)
        try fixture.turn("only", 1)
        try fixture.decide("only", "accepted")
        try fixture.ship("only")
        try fixture.append("only", .branchRemoved, data: ["reason": "merged"])
        let (store, _) = store()
        await store.open(fixture.root)
        #expect(snapshot(store)?.id == "only" && snapshot(store)?.spine[.clean].mark == .done)
    }

    // MARK: Doctor

    @Test func doctorDoesNotRunByItselfAndReportsAProblemWhenItCannot() async throws {
        let fixture = try await AppFixture()
        try await fixture.addThread("t1")
        let (store, _) = store()
        await store.open(fixture.root)
        #expect(store.doctor == .notRun)
        await store.runDoctor()
        if case .problem = store.doctor {} else { Issue.record("no config: \(store.doctor)") }
    }
}
