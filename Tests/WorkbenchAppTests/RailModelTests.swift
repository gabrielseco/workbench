import Foundation
import SwiftUI
import Testing
import WorkbenchCore

@testable import WorkbenchApp

@MainActor private var keptRailFixtures: [AppFixture] = []

/// The rail (design parity 4): what it lists, how a row says its state, and what choosing a row does.
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

    @Test func taskThreadsAreNotInTheRail() async throws {
        let shown = ThreadListing(rows: [thread("mine", .idle), thread("t-done", .done), thread("t-gone", .idle)], older: 3)
        let model = RailModel.derive(listing: shown, tasks: try await snapshot(naming: ["t-done", "t-gone"]))
        // A finished thread a task's run made is listed nowhere: not in THREADS, and nothing hangs under the task.
        #expect(model.threads.map(\.key) == ["mine"] && model.older == 3 && model.hidden == 0)
        #expect(model.tasks.map(\.kind).allSatisfy { $0 == .task }, "the tasks are rows of their own, nothing under them")
        // One that is working, needs you or is broken stays where it is seen.
        let marks: [ThreadMark] = [.working, .needsYou, .broken]
        let active = ThreadListing(rows: marks.map { thread("t-\($0.rawValue)", $0) })
        let kept = RailModel.derive(listing: active, tasks: try await snapshot(naming: active.rows.map(\.id)))
        #expect(kept.threads.map(\.key) == active.rows.map(\.id))
        // And once it ends it goes, with the rest of its task's runs.
        let ended = ThreadListing(rows: [thread("t-working", .done)])
        #expect(RailModel.derive(listing: ended, tasks: try await snapshot(naming: ["t-working"])).threads.isEmpty)
    }

    @Test func theShownTaskThreadIsListed() async throws {
        let shown = ThreadListing(rows: [thread("mine", .idle), thread("t-done", .done), thread("t-other", .done)])
        let tasks = try await snapshot(naming: ["t-done", "t-other"])
        // Reached by Open thread on a run: it is listed while it is on screen, so what is selected can be seen, and only that one.
        let model = RailModel.derive(listing: shown, tasks: tasks, shown: "t-done")
        #expect(model.threads.map(\.key) == ["mine", "t-done"])
        // Another row is chosen: it drops out again.
        #expect(RailModel.derive(listing: shown, tasks: tasks, shown: "mine").threads.map(\.key) == ["mine"])
    }

    @Test func aThreadYouStartedStaysEvenWhenItIsNamedLikeATask() async throws {
        let shown = ThreadListing(rows: [thread("bump-contract-details", .done), thread("update-docs", .idle)])
        let model = RailModel.derive(listing: shown, tasks: try await snapshot(naming: ["some-other-thread"]))
        #expect(model.threads.map(\.key) == ["bump-contract-details", "update-docs"])
    }

    @Test func nothingIsHiddenWhileTheTasksAreNotRead() {
        let shown = ThreadListing(rows: [thread("a", .done), thread("b", .idle)])
        let model = RailModel.derive(listing: shown, tasks: nil)
        #expect(model.threads.map(\.key) == ["a", "b"])
    }

    @Test func theThreadsListIsEmptyWhenEveryThreadBelongsToATask() async throws {
        let shown = ThreadListing(rows: [thread("a", .done)])
        let model = RailModel.derive(listing: shown, tasks: try await snapshot(naming: ["a"]))
        #expect(model.threads.isEmpty, "the rail then says No threads yet. rather than listing none")
    }

    // MARK: Ten at a time

    private func many(_ count: Int, pinned: [Int: ThreadMark] = [:]) -> ThreadListing {
        ThreadListing(rows: (0..<count).map { thread("t\($0)", pinned[$0] ?? .done) })
    }

    @Test func tenThreadsAndTheOnesThatNeedYou() {
        // 25 threads, newest first; two old ones need you or are working, and one is broken.
        let shown = many(25, pinned: [12: .needsYou, 18: .working, 24: .broken])
        let model = RailModel.derive(listing: shown, tasks: nil)
        let rest = (0..<25).filter { ![12, 18, 24].contains($0) }.prefix(10).map { "t\($0)" }
        let expected = shown.rows.map(\.id).filter { rest.contains($0) || ["t12", "t18", "t24"].contains($0) }
        #expect(model.threads.map(\.key) == expected)
        #expect(model.threads.count == 13, "ten of the rest, and the three that ask for something, whatever their age")
        #expect(model.hidden == 12 && model.older == 0, "22 others, ten listed")
        // Newest first within what is listed.
        #expect(model.threads.map(\.key).first == "t0" && model.threads.map(\.key).last == "t24")
    }

    @Test func showMoreAddsTen() {
        let shown = many(25)
        var limit = RailModel.pageSize
        var counts: [(listed: Int, hidden: Int)] = []
        for _ in 0..<4 {
            let model = RailModel.derive(listing: shown, tasks: nil, limit: limit)
            counts.append((model.threads.count, model.hidden))
            limit += RailModel.pageSize
        }
        #expect(counts.map(\.listed) == [10, 20, 25, 25] && counts.map(\.hidden) == [15, 5, 0, 0])
        // Ten or fewer: no line to press.
        #expect(RailModel.derive(listing: many(10), tasks: nil).hidden == 0)
        #expect(RailModel.derive(listing: many(3), tasks: nil).hidden == 0)
        #expect(RailModel.derive(listing: many(0), tasks: nil).threads.isEmpty)
    }

    @Test func theStoreRemembersHowManyForTheSession() async throws {
        let fixture = try await AppFixture()
        keptRailFixtures.append(fixture)
        try await AppScenario.threads.build(in: fixture)
        let store = ProjectStore(preferences: MemoryPreferences(projectPath: nil), actions: GoalActions())
        #expect(await store.open(fixture.root))
        #expect(store.railLimit == 10)
        store.showMoreThreads()
        store.showMoreThreads()
        #expect(store.railLimit == 30 && store.railExpanded)
        // Show less goes back to the first page in one press, however many pages were added.
        store.showFewerThreads()
        #expect(store.railLimit == 10 && !store.railExpanded)
    }

    @Test func theShownThreadIsAlwaysListed() {
        let shown = many(25)
        // An old thread chosen from the menu bar or a link: it is listed though the ten do not reach it, and takes no other's place.
        let model = RailModel.derive(listing: shown, tasks: nil, shown: "t20")
        #expect(model.threads.map(\.key) == (0..<10).map { "t\($0)" } + ["t20"])
        #expect(model.hidden == 14, "15 left out, now 14")
        // One inside the ten is just listed.
        #expect(RailModel.derive(listing: shown, tasks: nil, shown: "t3").hidden == 15)
    }

    @Test func arrowKeysSkipFoldedRows() {
        let model = RailModel.derive(listing: many(25), tasks: nil)
        let listed = model.threads.map(\.key)
        #expect(ThreadListView.neighbour(of: "t9", in: listed, up: false) == nil, "the last listed row has none below it")
        #expect(ThreadListView.neighbour(of: "t5", in: listed, up: false) == "t6")
        #expect(ThreadListView.neighbour(of: "t0", in: listed, up: true) == nil)
        #expect(!listed.contains("t10"), "a folded row is never what an arrow key lands on")
    }

    // MARK: Rows

    @Test func rowsAreOneLine() async throws {
        // The row draws its title and its mark; the words of its state are the hover text and the accessibility label.
        let said = ThreadRow(id: "t", title: "Fix the invoice list", mark: .needsYou, line: "Needs you · Findings open")
        let row = RailRow.thread(said)
        #expect(row.help == "Fix the invoice list: Needs you · Findings open")
        #expect(row.accessibility == "Fix the invoice list, needs you, Needs you · Findings open")
        let task = try #require(try await tasksSnapshot().entries.first.map(RailRow.task))
        #expect(task.help.hasPrefix("\(task.title): "), "a task's schedule and state are its hover text too")
        #expect(task.help.count > task.title.count + 2)
    }

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

    @Test func makingAThreadWhileATaskIsShownShowsTheNewThread() async throws {
        let fixture = try await AppFixture()
        keptRailFixtures.append(fixture)
        try await fixture.addThread("t1")
        let actions = GoalActions(
            draftGoal: { _, name, _, _, _ in GoalDraftResult(id: "g-\(name)", provider: .claude) },
            quickGoal: { _, name, _, _ in name })
        let store = ProjectStore(preferences: MemoryPreferences(projectPath: nil), actions: actions)
        #expect(await store.open(fixture.root))
        store.selectTask("nightly-lint")
        #expect(store.mode == .tasks)
        #expect(await store.quickGoal(request: "Fix it"))
        #expect(store.mode == .thread)
        // The same with a drafted goal (Do it now, the new-thread screen's Advanced).
        store.selectTask("nightly-lint")
        #expect(await store.draftGoal(request: "Fix it again"))
        #expect(store.mode == .thread, "a drafted goal")
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

    @Test func theRailShowsAThreadOnlyWhileAThreadIsWhatIsChosen() async throws {
        let fixture = try await AppFixture()
        keptRailFixtures.append(fixture)
        try await AppScenario.taskThreads.build(in: fixture)
        let store = ProjectStore(preferences: MemoryPreferences(projectPath: nil), actions: GoalActions())
        #expect(await store.open(fixture.root))
        let id = try #require(store.threads.listing.rows.first?.id)
        await store.select(thread: id)
        #expect(store.railShown == id, "the thread on screen")
        // A task chosen in the rail: its page is what shows, so the thread behind it is no longer the one to keep listed.
        store.selectTask("bump-contract-details")
        #expect(store.railShown == nil)
        await store.select(thread: id)
        #expect(store.railShown == id)
        // The new-thread screen is not a thread either.
        store.beginNewGoal()
        #expect(store.railShown == nil)
    }

    @Test func theOlderLineNamesTheCommandThatReachesThem() {
        #expect(RailModel.olderHelp(1).hasPrefix("1 older thread is past"), "one is singular")
        #expect(RailModel.olderHelp(10).hasPrefix("10 older threads are past"))
        for count in [1, 10] {
            let help = RailModel.olderHelp(count)
            #expect(help.contains("workbench status --all") && help.contains("workbench log <id>"), "\(help)")
        }
    }
}
