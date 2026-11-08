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

    @Test func theInboxListsTheThreadsAndTheTasksThatAsk() async throws {
        let shown = try await listing()
        let tasks = try await tasksSnapshot()
        let inbox = InboxModel.derive(listing: shown, tasks: tasks, doneOpen: true)
        let keys = inbox.threadRows.map(\.key)
        #expect(Set(keys) == Set(shown.rows.map(\.id)))
        #expect(inbox.threadRows.allSatisfy { $0.kind == .thread })
        let asking = tasks.entries.map(RailRow.task).filter { $0.mark == .needsYou }
        #expect(inbox.listed.filter(\.isAutomation).count == asking.count, "a task that asks is in the inbox as well")
        let taskIDs = tasks.entries.map(RailRow.task).map(\.id)
        #expect(Set(inbox.threadRows.map(\.id)).isDisjoint(with: taskIDs), "a thread and a task never share an id")
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
        let tasks = try await snapshot(naming: ["t-done", "t-gone"])
        let model = InboxModel.derive(listing: shown, tasks: tasks)
        // A finished thread a task's run made is listed nowhere: not in the inbox, and nothing hangs under the task.
        #expect(model.threadRows.map(\.key) == ["mine"] && model.older == 3)
        // One that is working, needs you or is broken stays where it is seen.
        let marks: [ThreadMark] = [.working, .needsYou, .broken]
        let active = ThreadListing(rows: marks.map { thread("t-\($0.rawValue)", $0) })
        let kept = InboxModel.derive(listing: active, tasks: try await snapshot(naming: active.rows.map(\.id)))
        #expect(Set(kept.threadRows.map(\.key)) == Set(active.rows.map(\.id)))
        // And once it ends it goes, with the rest of its task's runs.
        let ended = ThreadListing(rows: [thread("t-working", .done)])
        #expect(InboxModel.derive(listing: ended, tasks: try await snapshot(naming: ["t-working"])).threadRows.isEmpty)
    }

    @Test func theShownTaskThreadIsListed() async throws {
        let shown = ThreadListing(rows: [thread("mine", .idle), thread("t-done", .done), thread("t-other", .done)])
        let tasks = try await snapshot(naming: ["t-done", "t-other"])
        // Reached by Open thread on a run: it is listed while it is on screen, so what is selected can be seen, and only that one.
        let model = InboxModel.derive(listing: shown, tasks: tasks, shown: "t-done")
        #expect(model.threadRows.map(\.key) == ["mine", "t-done"])
        // Another row is chosen: it drops out again.
        #expect(InboxModel.derive(listing: shown, tasks: tasks, shown: "mine").threadRows.map(\.key) == ["mine"])
    }

    @Test func aThreadYouStartedStaysEvenWhenItIsNamedLikeATask() async throws {
        let shown = ThreadListing(rows: [thread("bump-contract-details", .done), thread("update-docs", .idle)])
        let model = InboxModel.derive(listing: shown, tasks: try await snapshot(naming: ["some-other-thread"]))
        #expect(model.threadRows.map(\.key) == ["bump-contract-details", "update-docs"])
    }

    @Test func nothingIsHiddenWhileTheTasksAreNotRead() {
        let shown = ThreadListing(rows: [thread("a", .done), thread("b", .idle)])
        let model = InboxModel.derive(listing: shown, tasks: nil)
        #expect(model.threadRows.map(\.key) == ["a", "b"])
    }

    @Test func theThreadsListIsEmptyWhenEveryThreadBelongsToATask() async throws {
        let shown = ThreadListing(rows: [thread("a", .done)])
        let model = InboxModel.derive(listing: shown, tasks: try await snapshot(naming: ["a"]))
        #expect(model.threadRows.isEmpty && model.finishedCount == 0, "the rail then says No threads yet.")
    }

    // MARK: Sections

    private func finished(_ id: String, _ mark: ThreadMark = .done) -> ThreadRow {
        ThreadRow(id: id, title: id, mark: mark, line: "x", finished: true)
    }

    @Test func threadsSortIntoNeedsYouWaitingAndDone() {
        let rows = [
            thread("asks", .needsYou), thread("works", .working), finished("over"), thread("broke", .broken),
            thread("drafts", .idle), finished("thrown", .idle),
        ]
        let model = InboxModel.derive(listing: ThreadListing(rows: rows), tasks: nil, doneOpen: true)
        #expect(model.needsYou.map(\.key) == ["asks", "broke"], "a broken thread needs you: it cannot go on without a person")
        #expect(model.waiting.map(\.key) == ["works", "drafts"])
        #expect(model.done.map(\.key) == ["over", "thrown"] && model.doneHidden == 0)
        #expect(model.listed.map(\.key) == ["asks", "broke", "works", "drafts", "over", "thrown"], "drawn in that order")
        #expect(Set(model.listed.map(\.id)).count == rows.count, "each thread is in exactly one section")
    }

    @Test func doneIsCollapsedToACountUntilItIsOpened() {
        let rows = [thread("asks", .needsYou)] + (0..<12).map { finished("f\($0)") }
        let closed = InboxModel.derive(listing: ThreadListing(rows: rows), tasks: nil)
        #expect(closed.done.isEmpty && closed.doneHidden == 12 && closed.finishedCount == 12)
        #expect(closed.listed.map(\.key) == ["asks"], "the finished are not rows until asked for")
        let open = InboxModel.derive(listing: ThreadListing(rows: rows), tasks: nil, doneOpen: true)
        #expect(open.done.count == 12 && open.doneHidden == 0 && open.finishedCount == 12)
        // The one on screen is listed even while Done is closed, so what is selected can be seen.
        let shown = InboxModel.derive(listing: ThreadListing(rows: rows), tasks: nil, shown: "f7")
        #expect(shown.done.map(\.key) == ["f7"] && shown.doneHidden == 11 && shown.finishedCount == 12)
    }

    @Test func aNeedsYouTaskIsAnAutoRowAmongTheThreadsThatNeedYou() async throws {
        var tasks = try await snapshot(naming: [])
        let at = try #require(tasks.entries.firstIndex { $0.id == "bump-contract-details" })
        tasks.entries[at].summary.approval = .never
        let asking = tasks.entries.map(RailRow.task).filter { $0.mark == .needsYou }.map(\.key)
        #expect(asking.contains("bump-contract-details"))
        let model = InboxModel.derive(listing: ThreadListing(rows: [thread("asks", .needsYou)]), tasks: tasks)
        let autos = model.needsYou.filter(\.isAutomation)
        #expect(model.needsYou.first?.key == "asks", "the threads first")
        #expect(autos.map(\.key) == asking, "every task that asks, after them")
        #expect(autos.allSatisfy { $0.mark == .needsYou && $0.spend == nil })
        #expect(autos.first?.accessibility.hasSuffix("automation") == true, "told in words, not by the tag alone")
        // A task that asks nothing is not in the inbox: it stays in Scheduled.
        let quiet = InboxModel.derive(listing: ThreadListing(rows: []), tasks: try await tasksSnapshot(.tasksEmpty))
        #expect(quiet.listed.isEmpty)
    }

    @Test func arrowKeysWalkWhatIsDrawnIncludingAutomationRows() async throws {
        var tasks = try await snapshot(naming: [])
        let at = try #require(tasks.entries.firstIndex { $0.id == "bump-contract-details" })
        tasks.entries[at].summary.approval = .never
        let model = InboxModel.derive(listing: ThreadListing(rows: [thread("a", .needsYou), thread("c", .working)]), tasks: tasks)
        let names = tasks.entries.map(\.id)
        let asking = tasks.entries.map(RailRow.task).filter { $0.mark == .needsYou }.map(\.key)
        let order = model.navigation(scheduled: names)
        let drawn = model.listed.map { ($0.isAutomation ? "k:" : "t:") + $0.key }
        #expect(Array(order.prefix(drawn.count)) == drawn, "the inbox's rows as drawn, automations among them")
        let others = names.filter { $0 != "bump-contract-details" && !asking.contains($0) }.map { "s:" + $0 }
        #expect(Array(order.dropFirst(drawn.count)) == others, "then the Scheduled tasks the inbox does not show")
        #expect(Set(order).count == order.count && !order.contains("s:bump-contract-details"), "a task is one stop")
        let first = try #require(drawn.first)
        let below = InboxModel.neighbour(of: first, in: order, up: false)
        #expect(first == "t:a" && below == drawn[1], "down from A is the next row")
        // Pressing Down from where each press lands visits every stop once and then stops: it cannot loop.
        var visited = [first]
        while let step = InboxModel.neighbour(of: visited.last, in: order, up: false), visited.count <= order.count {
            let key = String(step.dropFirst(2))
            let isTask = !step.hasPrefix("t:")
            visited.append(model.navigationID(thread: isTask ? nil : key, task: isTask ? key : nil) ?? step)
        }
        #expect(visited == order, "each press lands on the next stop, through to the last")
        let auto = try #require(drawn.first { $0.hasPrefix("k:") })
        #expect(InboxModel.neighbour(of: auto, in: order, up: true) != nil, "an automation row can be stepped from")
        // The task's page, reached from either row, is the stop in the inbox when there is one.
        #expect(model.navigationID(thread: nil, task: "bump-contract-details") == "k:bump-contract-details")
        let quiet = InboxModel.derive(listing: ThreadListing(rows: [thread("a", .needsYou)]), tasks: nil)
        #expect(quiet.navigationID(thread: nil, task: "bump-contract-details") == "s:bump-contract-details")
        #expect(quiet.navigationID(thread: "a", task: nil) == "t:a")
    }

    @Test func theStoreRemembersWhichProjectsHaveDoneOpen() async throws {
        let first = try await AppFixture()
        let second = try await AppFixture()
        keptRailFixtures.append(contentsOf: [first, second])
        try await AppScenario.threads.build(in: first)
        try await AppScenario.threads.build(in: second)
        let store = ProjectStore(preferences: MemoryPreferences(projectPath: nil), actions: GoalActions())
        #expect(await store.open(first.root))
        #expect(!store.doneOpen)
        store.toggleDoneOpen()
        #expect(store.doneOpen)
        #expect(await store.open(second.root))
        #expect(!store.doneOpen, "another project's Done is its own")
        #expect(await store.open(first.root))
        #expect(store.doneOpen, "and the first one is as it was left")
        store.toggleDoneOpen()
        #expect(!store.doneOpen)
    }

    @Test func arrowKeysFollowTheListedRows() {
        let rows = [thread("a", .needsYou), thread("b", .working)] + (0..<5).map { finished("f\($0)") }
        let model = InboxModel.derive(listing: ThreadListing(rows: rows), tasks: nil)
        let listed = model.listed.map(\.key)
        #expect(InboxModel.neighbour(of: "b", in: listed, up: false) == nil, "the last listed row has none below it")
        #expect(InboxModel.neighbour(of: "a", in: listed, up: false) == "b")
        #expect(InboxModel.neighbour(of: "a", in: listed, up: true) == nil)
        #expect(!listed.contains("f0"), "a folded row is never what an arrow key lands on")
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
        #expect(InboxModel.olderHelp(1).hasPrefix("1 older thread is past"), "one is singular")
        #expect(InboxModel.olderHelp(10).hasPrefix("10 older threads are past"))
        for count in [1, 10] {
            let help = InboxModel.olderHelp(count)
            #expect(help.contains("workbench status --all") && help.contains("workbench log <id>"), "\(help)")
        }
    }
}
