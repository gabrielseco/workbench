import Foundation
import Testing
import WorkbenchCore

@testable import WorkbenchApp

@MainActor private var keptAllInboxFixtures: [AppFixture] = []

/// P26 slice 4b: the inbox of every project on the rail.
@MainActor @Suite struct AllInboxTests {
    private func row(_ id: String, _ mark: ThreadMark, finished: Bool = false) -> InboxRow {
        InboxRow(thread: ThreadRow(id: id, title: id, mark: mark, line: "x", finished: finished))
    }

    private func project(_ name: String, _ rows: [InboxRow]) -> ProjectInboxRows {
        ProjectInboxRows(path: "/p/\(name)", name: name, initials: name.prefix(2).uppercased(), rows: rows)
    }

    /// The `tasks` scenario's entries, read with the machine's schedulers and probes stood in for.
    private func taskEntries(_ scenario: AppScenario = .tasks) async throws -> [TaskEntry] {
        let fixture = try await AppFixture(git: false)
        keptAllInboxFixtures.append(fixture)
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
        let reader = TasksReader.core(environment: env)
        return try await reader.read(fixture.project, Date(timeIntervalSince1970: 1_793_500_000)).entries
    }

    // MARK: The model

    @Test func theSectionsHoldEveryProjectsRowsInTheRailsOrder() {
        let api = project("api", [row("a1", .needsYou), row("a2", .working), row("a3", .done, finished: true)])
        let web = project("web", [row("w1", .broken), row("w2", .idle), row("w3", .idle, finished: true)])
        let model = AllInboxModel.derive([api, web], doneOpen: true)
        #expect(model.needsYou.map(\.row.key) == ["a1", "w1"], "a broken thread needs you; projects in the rail's order")
        #expect(model.waiting.map(\.row.key) == ["a2", "w2"])
        #expect(model.done.map(\.row.key) == ["a3", "w3"] && model.doneHidden == 0)
        #expect(model.needsYou.map(\.initials) == ["AP", "WE"], "each row says whose it is")
        #expect(Set((model.needsYou + model.waiting + model.done).map(\.id)).count == 6, "one row each, ids that never meet")
    }

    @Test func doneIsOneCountUntilItIsOpened() {
        let api = project("api", (0..<3).map { row("a\($0)", .done, finished: true) })
        let web = project("web", (0..<4).map { row("w\($0)", .idle, finished: true) })
        let closed = AllInboxModel.derive([api, web], doneOpen: false)
        #expect(closed.done.isEmpty && closed.doneHidden == 7 && closed.finishedCount == 7 && !closed.isEmpty)
        #expect(AllInboxModel.derive([api, web], doneOpen: true).done.count == 7)
        #expect(AllInboxModel.derive([], doneOpen: false).isEmpty)
        #expect(AllInboxModel.derive([project("api", [])], doneOpen: true).isEmpty, "a project with nothing adds nothing")
    }

    @Test func aTaskThatAsksIsAnAutomationRowInItsProjectsNeedsYou() async throws {
        let entries = try await taskEntries()
        let asking = entries.map(RailRow.task).filter { $0.mark == .needsYou }.map(\.key)
        let rows = InboxModel.rows(listing: ThreadListing(rows: []), entries: entries)
        #expect(!asking.isEmpty && rows.filter(\.isAutomation).map(\.key) == asking)
        let model = AllInboxModel.derive([project("api", rows)], doneOpen: false)
        #expect(model.needsYou.map(\.row.key) == asking && model.needsYou.allSatisfy { $0.row.isAutomation })
        #expect(model.needsYou.first?.accessibility.hasSuffix("in api") == true, "said in words, not only by its chip")
    }

    @Test func threadsOfATasksRunsAreLeftOutAsTheyAreInTheProjectsOwnInbox() async throws {
        var entries = try await taskEntries()
        let at = try #require(entries.firstIndex { $0.id == "bump-contract-details" })
        entries[at].runs = [
            TaskHistory.Run(
                started: Date(timeIntervalSince1970: 1), ended: nil, pullRequest: nil, trigger: "tick", outcome: .prOpened,
                reason: nil, units: [], thread: "t-run")
        ]
        let listing = ThreadListing(rows: [
            ThreadRow(id: "t-run", title: "t-run", mark: .done, line: "x", finished: true),
            ThreadRow(id: "mine", title: "mine", mark: .working, line: "x"),
        ])
        let keys = InboxModel.rows(listing: listing, entries: entries).filter { !$0.isAutomation }.map(\.key)
        #expect(keys == ["mine"])
    }

    // MARK: The store

    private func fixture(needsYou: Int = 0) async throws -> AppFixture {
        let fixture = try await AppFixture()
        keptAllInboxFixtures.append(fixture)
        for index in 0..<needsYou {
            try await fixture.addThread("n\(index)", approved: true, title: "Asks \(index)")
            try fixture.turn("n\(index)", 1)
        }
        return fixture
    }

    private func store(open: AppFixture, others: [AppFixture]) async -> ProjectStore {
        let preferences = MemoryPreferences(projectPath: nil)
        preferences.railProjects = ([open] + others).map(\.project.root.path)
        let store = ProjectStore(preferences: preferences)
        _ = await store.open(open.root)
        return store
    }

    @Test func choosingTheTopTileReadsTheOtherProjectsRows() async throws {
        let open = try await fixture(needsYou: 1)
        let api = try await fixture(needsYou: 2)
        let store = await store(open: open, others: [api])
        await store.reload()
        let before = store.allInboxModel().needsYou.map(\.project)
        #expect(before == [open.project.root.path], "the open one live; the other not read yet")
        await store.showAllProjects()
        #expect(store.allProjects)
        let paths = store.allInboxModel().needsYou.map(\.project)
        #expect(paths == [open, api, api].map { $0.project.root.path }, "the rail's order, each project's rows together")
    }

    @Test func aRowIsNotReadUntilTheTopTileIsChosen() async throws {
        let open = try await fixture()
        let api = try await fixture(needsYou: 1)
        let store = await store(open: open, others: [api])
        await store.readRailSummaries()
        #expect(store.railSummaries.rows.isEmpty, "the poll reads counts only while the project's own inbox is up")
        #expect(store.railBadge(for: api.project.root.path) == .needsYou(1))
    }

    @Test func aClickOpensTheProjectAndShowsTheThreadAndLeavesTheList() async throws {
        let open = try await fixture()
        let api = try await fixture(needsYou: 1)
        let store = await store(open: open, others: [api])
        await store.showAllProjects()
        let entry = try #require(store.allInboxModel().needsYou.first)
        #expect(entry.project == api.project.root.path)
        await store.open(entry)
        #expect(store.project?.root.path == api.project.root.path, "its project is open")
        guard case .thread(let shown) = store.screen else {
            Issue.record("a thread should be on screen")
            return
        }
        #expect(shown.id == "n0")
        #expect(!store.allProjects, "the rail is that project's own inbox now")
    }

    @Test func aProjectTileGoesBackToItsOwnInbox() async throws {
        let open = try await fixture()
        let api = try await fixture(needsYou: 1)
        let store = await store(open: open, others: [api])
        await store.showAllProjects()
        await store.pickRecent(open.project.root.path)
        #expect(!store.allProjects, "the open project's own tile too")
        await store.showAllProjects()
        await store.pickRecent(api.project.root.path)
        #expect(!store.allProjects && store.project?.root.path == api.project.root.path)
    }

    @Test func aFolderThatIsGoneIsNotInTheListAndAProjectThatCannotOpenKeepsTheList() async throws {
        let open = try await fixture()
        let gone = try await fixture(needsYou: 1)
        let store = await store(open: open, others: [gone])
        await store.showAllProjects()
        #expect(store.allInboxModel().needsYou.count == 1)
        try FileManager.default.removeItem(at: gone.root)
        await store.readRailSummaries()
        #expect(store.allInboxModel().isEmpty, "its tile says it is gone; its rows are not listed")
        await store.pickRecent(gone.project.root.path)
        #expect(store.allProjects, "a refusal leaves the list that was up")
    }

    @Test func doneOfAllProjectsIsOneFlagAndTheOpenProjectsOwnIsItsOwn() async throws {
        let open = try await fixture()
        let store = await store(open: open, others: [])
        #expect(!store.allInboxDoneOpen && !store.doneOpen)
        store.toggleAllDoneOpen()
        #expect(store.allInboxDoneOpen && !store.doneOpen, "the project's Done fold is not the all-projects one")
    }
}
