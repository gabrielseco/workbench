import Foundation
import SwiftUI
import Testing
import WorkbenchCore

@testable import WorkbenchApp

@MainActor private var keptRailFixtures: [AppFixture] = []

/// The rail with the preview on (design parity 4): what it lists, how a row says its state, and what choosing a row does.
@MainActor @Suite struct RailModelTests {
    private func tasksSnapshot(_ scenario: AppScenario = .tasks) async throws -> TasksSnapshot {
        let fixture = try await AppFixture(git: false)
        keptRailFixtures.append(fixture)
        try await scenario.build(in: fixture)
        let probes = fixture.root.appendingPathComponent("probes")
        try FileManager.default.createDirectory(at: probes, withIntermediateDirectories: true)
        let answers = [
            ("sched", "Repeating power events:\n"), ("power", "Now drawing from 'AC Power'\n"),
            ("filevault", "FileVault is On.\n"),
        ]
        for (name, text) in answers {
            try text.write(to: probes.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let env = [
            "WORKBENCH_APP_HOME": fixture.root.appendingPathComponent("home").path,
            "WORKBENCH_APP_LAUNCHCTL": "/nonexistent/launchctl", "WORKBENCH_APP_PROBES": probes.path,
        ]
        return try await TasksReader.core(environment: env).read(fixture.project, Date(timeIntervalSince1970: 1_793_500_000))
    }

    private func listing() async throws -> ThreadListing {
        let fixture = try await AppFixture()
        keptRailFixtures.append(fixture)
        try await AppScenario.threads.build(in: fixture)
        return ThreadListLoader.load(project: fixture.project, cache: .init())
    }

    // MARK: Sections

    @Test func theRailListsTheThreadsThenTheTasksWithTheirCount() async throws {
        let shown = try await listing()
        let tasks = try await tasksSnapshot()
        let model = RailModel.derive(listing: shown, tasks: tasks)
        #expect(model.threads.map(\.key) == shown.rows.map(\.id) && model.threads.allSatisfy { $0.kind == .thread })
        #expect(model.tasks.map(\.key) == tasks.entries.map(\.id) && model.tasks.allSatisfy { $0.kind == .task })
        #expect(model.scheduledHeader == "SCHEDULED · \(tasks.entries.count)" && model.scheduledNote == nil)
        #expect(Set(model.threads.map(\.id)).isDisjoint(with: model.tasks.map(\.id)), "a thread and a task never share a row id")
    }

    @Test func aProjectWithNoTasksSaysSoAndOneNotReadYetSaysThatInstead() async throws {
        let shown = try await listing()
        let empty = try await tasksSnapshot(.tasksEmpty)
        #expect(empty.entries.isEmpty, "the tasks-empty fixture has none")
        let none = RailModel.derive(listing: shown, tasks: empty)
        #expect(none.scheduledHeader == "SCHEDULED · 0")
        #expect(none.scheduledNote?.hasPrefix("No scheduled tasks.") == true)
        let unread = RailModel.derive(listing: shown, tasks: nil)
        #expect(unread.scheduledNote == "Reading…", "not read yet is not the same as none")
    }

    // MARK: A task's threads

    private func thread(_ id: String, _ mark: ThreadMark) -> ThreadRow { ThreadRow(id: id, title: id, mark: mark, line: "x") }

    private func run(thread: String?) -> TaskHistory.Run {
        TaskHistory.Run(
            started: Date(timeIntervalSince1970: 1), ended: nil, pullRequest: nil, trigger: "tick", outcome: .prOpened,
            reason: nil, units: [], thread: thread)
    }

    /// The `tasks` fixture with `bump-contract-details` having started `threads`.
    private func snapshot(naming threads: [String]) async throws -> TasksSnapshot {
        var snapshot = try await tasksSnapshot()
        let at = try #require(snapshot.entries.firstIndex { $0.id == "bump-contract-details" })
        snapshot.entries[at].runs = threads.map { run(thread: $0) } + [run(thread: nil)]
        return snapshot
    }

    @Test func aFinishedThreadATaskStartedMovesUnderItsTask() async throws {
        let shown = ThreadListing(rows: [thread("mine", .idle), thread("t-done", .done), thread("t-gone", .idle)], older: 3)
        let model = RailModel.derive(listing: shown, tasks: try await snapshot(naming: ["t-done", "t-gone"]))
        #expect(model.threads.map(\.key) == ["mine"] && model.older == 3)
        #expect(model.taskThreads["bump-contract-details"]?.map(\.key) == ["t-done", "t-gone"], "newest first, as listed")
        #expect(model.taskThreads["bump-contract-details"]?.allSatisfy { $0.kind == .thread } == true)
    }

    @Test func aTaskThreadThatIsWorkingNeedsYouOrIsBrokenStaysInThreads() async throws {
        let marks: [ThreadMark] = [.working, .needsYou, .broken]
        let shown = ThreadListing(rows: marks.map { thread("t-\($0.rawValue)", $0) })
        let model = RailModel.derive(listing: shown, tasks: try await snapshot(naming: shown.rows.map(\.id)))
        #expect(model.threads.map(\.key) == shown.rows.map(\.id) && model.taskThreads.isEmpty)
        // Once it ends, the same thread goes under its task.
        let ended = ThreadListing(rows: [thread("t-working", .done)])
        let later = RailModel.derive(listing: ended, tasks: try await snapshot(naming: ["t-working"]))
        #expect(later.threads.isEmpty && later.taskThreads["bump-contract-details"]?.map(\.key) == ["t-working"])
    }

    @Test func aThreadYouStartedStaysEvenWhenItIsNamedLikeATask() async throws {
        let shown = ThreadListing(rows: [thread("bump-contract-details", .done), thread("update-docs", .idle)])
        let model = RailModel.derive(listing: shown, tasks: try await snapshot(naming: ["some-other-thread"]))
        #expect(model.threads.map(\.key) == ["bump-contract-details", "update-docs"] && model.taskThreads.isEmpty)
    }

    @Test func theGroupHoldingAThreadIsFoundSoTheRailCanOpenIt() async throws {
        let shown = ThreadListing(rows: [thread("mine", .idle), thread("t-done", .done)])
        let before = RailModel.derive(listing: shown, tasks: nil)
        #expect(before.group(holding: "t-done") == nil, "not read yet: the thread is in Threads")
        let after = RailModel.derive(listing: shown, tasks: try await snapshot(naming: ["t-done"]))
        #expect(after.group(holding: "t-done") == "bump-contract-details")
        #expect(after.group(holding: "mine") == nil && after.group(holding: nil) == nil)
    }

    @Test func nothingIsHiddenWhileTheTasksAreNotRead() {
        let shown = ThreadListing(rows: [thread("a", .done), thread("b", .idle)])
        let model = RailModel.derive(listing: shown, tasks: nil)
        #expect(model.threads.map(\.key) == ["a", "b"] && model.taskThreads.isEmpty)
    }

    @Test func theThreadsListIsEmptyWhenEveryThreadBelongsToATask() async throws {
        let shown = ThreadListing(rows: [thread("a", .done)])
        let model = RailModel.derive(listing: shown, tasks: try await snapshot(naming: ["a"]))
        #expect(model.threads.isEmpty, "the rail then says No threads yet. rather than listing none")
    }

    // MARK: Rows

    @Test func aThreadRowKeepsItsTitleMarkAndLineInTheRail() async throws {
        for row in try await listing().rows {
            let rail = RailRow.thread(row)
            #expect(rail.kind == .thread && rail.key == row.id && rail.title == row.title)
            #expect(rail.mark == row.mark && rail.line == row.line)
        }
    }

    @Test func eachTaskStateHasItsMarkAndItsLine() async throws {
        let rows = Dictionary(uniqueKeysWithValues: try await tasksSnapshot().entries.map { ($0.id, RailRow.task($0)) })
        let expected: [String: ThreadMark] = [
            "broken-task": .broken, "cleanup-branches": .needsYou, "update-docs": .needsYou, "nightly-lint": .working,
            "sync-fixtures": .broken, "weekly-report": .done, "bump-contract-details": .idle,
        ]
        for (name, mark) in expected { #expect(rows[name]?.mark == mark, "\(name): \(String(describing: rows[name]))") }
        #expect(rows["cleanup-branches"]?.line.hasSuffix("not approved") == true)
        #expect(rows["update-docs"]?.line.hasSuffix("approval stale") == true)
        #expect(rows["nightly-lint"]?.line.hasSuffix("running") == true)
        #expect(rows["broken-task"]?.line.hasSuffix("needs a fix") == true)
        #expect(rows["bump-contract-details"]?.line.hasPrefix("weekdays 04:00 · ") == true, "the schedule comes first")
    }

    @Test func aTaskThatWasNeverRunSaysSo() async throws {
        let entries = try await tasksSnapshot().entries
        var never = try #require(entries.first { $0.id == "bump-contract-details" })
        never.runs = []
        #expect(RailRow.task(never).line.hasSuffix("never run") && RailRow.task(never).mark == .idle)
    }

    @Test func onlyAStateThatAsksOrFinishedIsColouredInTheLine() {
        #expect(ThreadMark.idle.lineTint == .quiet)
        for mark in [ThreadMark.working, .needsYou, .done, .broken] { #expect(mark.lineTint == .mark, "\(mark)") }
    }

    // MARK: Choosing

    @Test func choosingATaskShowsItAndChoosingAThreadShowsTheThread() async throws {
        let fixture = try await AppFixture()
        keptRailFixtures.append(fixture)
        try await fixture.addThread("t1")
        try await fixture.addThread("t2")
        let store = ProjectStore(preferences: MemoryPreferences(projectPath: nil))
        #expect(await store.open(fixture.root))
        #expect(store.mode == .thread)
        store.selectTask("nightly-lint")
        #expect(store.mode == .tasks && store.tasks.selection == "nightly-lint")
        await store.select(thread: "t1")
        #expect(store.mode == .thread, "choosing a thread leaves the task, even the thread already shown")
        store.selectTask("weekly-report")
        await store.select(thread: store.currentThread ?? "t1")
        #expect(store.mode == .thread)
    }

    @Test func makingAThreadWhileATaskIsShownShowsTheNewThreadWithThePreviewOnAndLeavesTheOldWindowAlone() async throws {
        for preview in [true, false] {
            let fixture = try await AppFixture()
            keptRailFixtures.append(fixture)
            try await fixture.addThread("t1")
            let preferences = MemoryPreferences(projectPath: nil)
            preferences.chatFeed = preview
            let actions = GoalActions(
                draftGoal: { _, name, _, _, _ in GoalDraftResult(id: "g-\(name)", provider: .claude) },
                quickGoal: { _, name, _, _ in name })
            let store = ProjectStore(preferences: preferences, actions: actions)
            #expect(await store.open(fixture.root))
            store.selectTask("nightly-lint")
            #expect(store.mode == .tasks)
            #expect(await store.quickGoal(request: "Fix it"))
            #expect(store.mode == (preview ? .thread : .tasks), "preview \(preview)")
            // The same with a drafted goal (Do it now, the popover's Advanced).
            store.selectTask("nightly-lint")
            #expect(await store.draftGoal(request: "Fix it again"))
            #expect(store.mode == (preview ? .thread : .tasks), "a drafted goal, preview \(preview)")
        }
    }

    @Test func theEmptyTasksPageCanBeOpenedFromTheRail() async throws {
        let fixture = try await AppFixture()
        keptRailFixtures.append(fixture)
        try await fixture.addThread("t1")
        let store = ProjectStore(preferences: MemoryPreferences(projectPath: nil))
        #expect(await store.open(fixture.root))
        #expect(store.mode == .thread)
        store.showTasks()
        #expect(store.mode == .tasks)
    }

    // MARK: Width

    @Test func theRailIsTheDesignsWidthAndTheInspectorStillGoesOverTheFeedWhenTheCentreIsNarrow() {
        #expect(PreviewRail.width == 288)
        #expect(RunSettingsLayout.placement(centreWidth: 900 - PreviewRail.width) == .sheet, "the 900 minimum")
        #expect(RunSettingsLayout.placement(centreWidth: 1240 - PreviewRail.width) == .beside)
    }
}
