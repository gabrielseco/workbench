import Foundation
import Testing
import WorkbenchCore

@testable import WorkbenchApp

@MainActor private var keptTaskStateFixtures: [AppFixture] = []

/// Disabled and archived tasks on the Tasks screen: what each says, where each is listed, and what the buttons do (through core).
@MainActor @Suite struct TaskStateTests {
    private let now = Date(timeIntervalSince1970: 1_793_500_000)

    private func fixture() async throws -> (AppFixture, TasksReader) {
        let fixture = try await AppFixture(git: false)
        keptTaskStateFixtures.append(fixture)
        try await AppScenario.tasks.build(in: fixture)
        let env = [
            "WORKBENCH_APP_HOME": fixture.root.appendingPathComponent("home").path,
            "WORKBENCH_APP_LAUNCHCTL": "/nonexistent/launchctl",
        ]
        return (fixture, .core(environment: env))
    }

    private let clean = TimerCard.lines([TimerStatusLine(level: .ok, text: "launchd job installed")])

    @Test func aDisabledTaskIsListedAndSaysItIsOff() async throws {
        let (fixture, reader) = try await fixture()
        let snapshot = try await reader.read(fixture.project, now)
        let entry = try #require(snapshot.entries.first { $0.id == "refresh-snapshots" })
        #expect(!entry.summary.enabled && entry.summary.nextDue == nil)
        #expect(TaskPage.State(entry.summary) == .disabled && TaskPage.State(entry.summary).note != nil)
        #expect(TaskPage.header(entry, now: now).line.contains("next never (disabled)"))
        let row = RailRow.task(entry)
        #expect(row.line == "weekdays 03:00 · disabled" && row.mark == .idle, "turned off on purpose asks nothing of you")
        // Tonight's verdict says so first, with the button that turns it back on.
        let tonight = RunTonight.derive(entry, timer: clean, activeThread: nil)
        #expect(tonight.verdict == .willNotRun && tonight.warnings.first?.action == .enable)
        // Run now is still offered: disabling stops the schedule, not a person.
        #expect(TasksModel(reader: reader).runUnavailable(entry, threadRunGoing: false) == nil)
        // An enabled one says nothing more than before.
        let bump = try #require(snapshot.entries.first { $0.id == "bump-contract-details" })
        #expect(TaskPage.State(bump.summary) == .enabled && TaskPage.State(bump.summary).note == nil)
        #expect(!RunTonight.derive(bump, timer: clean, activeThread: nil).warnings.contains { $0.action == .enable })
    }

    @Test func anArchivedTaskIsApartWithItsRunsAndCannotRun() async throws {
        let (fixture, reader) = try await fixture()
        let snapshot = try await reader.read(fixture.project, now)
        #expect(!snapshot.entries.contains { $0.id == "migrate-ledger" }, "not on the active list")
        let archived = try #require(snapshot.archived.first { $0.id == "migrate-ledger" })
        #expect(archived.runs.count == 2 && archived.summary.problem == nil, "its runs and its definition are kept")
        #expect(TaskPage.State(archived.summary) == .archived(enabled: true))
        #expect(TaskPage.header(archived, now: now).path == ".workbench/tasks/migrate-ledger/task.md")
        #expect(TasksModel(reader: reader).runUnavailable(archived, threadRunGoing: false) != nil)
        // What counts and notifies reads only the active tasks.
        #expect(!(try TasksReader.entries(fixture.project, now: now)).contains { $0.id == "migrate-ledger" })
        // The arrows walk it only while its fold is open.
        #expect(!AutomationsList.walked(snapshot, archivedOpen: false).contains("migrate-ledger"))
        #expect(AutomationsList.walked(snapshot, archivedOpen: true).last == "migrate-ledger")
        // Chosen, it is the one shown.
        let model = TasksModel(reader: reader)
        model.selection = "migrate-ledger"
        #expect(model.selected(in: snapshot)?.id == "migrate-ledger")
    }

    @Test func theButtonsChangeTheStateThroughCoreAndKeepTheTaskShown() async throws {
        let (fixture, reader) = try await fixture()
        let model = TasksModel(reader: reader)
        await model.refresh(fixture.project)

        await model.change(fixture.project, "bump-contract-details", .disable)
        var shown = try #require(model.snapshot(for: fixture.project))
        #expect(shown.entries.first { $0.id == "bump-contract-details" }?.summary.enabled == false)
        #expect(model.selection == "bump-contract-details" && model.actionNote == nil)

        await model.change(fixture.project, "bump-contract-details", .archive)
        shown = try #require(model.snapshot(for: fixture.project))
        #expect(shown.archived.map(\.id).contains("bump-contract-details"))
        #expect(model.selected(in: shown)?.id == "bump-contract-details", "the page stays on it, now with Restore")

        await model.change(fixture.project, "bump-contract-details", .restore)
        shown = try #require(model.snapshot(for: fixture.project))
        let back = try #require(shown.entries.first { $0.id == "bump-contract-details" })
        #expect(!back.summary.archived && !back.summary.enabled, "restored as it was: disabled")
        #expect(TaskPage.State(back.summary) == .disabled)

        await model.change(fixture.project, "bump-contract-details", .enable)
        shown = try #require(model.snapshot(for: fixture.project))
        #expect(shown.entries.first { $0.id == "bump-contract-details" }?.summary.enabled == true)
    }

    @Test func aRefusalIsANoteAndNothingChanges() async throws {
        let (fixture, reader) = try await fixture()
        var actions = TaskActions.core
        actions.change = { _, name, _ in throw TaskStateError.running(name) }
        let model = TasksModel(reader: reader, actions: actions)
        await model.refresh(fixture.project)
        await model.change(fixture.project, "sync-fixtures", .archive)
        #expect(model.actionNote?.hasPrefix("sync-fixtures cannot be archived") == true)
        #expect(model.snapshot(for: fixture.project)?.entries.contains { $0.id == "sync-fixtures" } == true)
        // A task with a run going cannot be changed from the page.
        let running = try #require(model.snapshot(for: fixture.project)?.entries.first { $0.isRunning })
        #expect(model.changeUnavailable(running, in: fixture.project) != nil)
    }
}
