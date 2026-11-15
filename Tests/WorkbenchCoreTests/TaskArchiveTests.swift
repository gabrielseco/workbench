import Foundation
import Testing

@testable import WorkbenchCore

/// Archiving a task: off the active list and never run, with its file, its reports and its runs kept, until it is restored.
@Suite(.processGate) struct TaskArchiveTests {
    private typealias S = TaskSchedulingTests

    @Test func archivePreservesTaskAndHistory() async throws {
        let fx = try S.reportTask()
        let other = try TaskFixture(in: fx.project, name: "other", front: "at: 05:00\nfix: report")
        try await fx.library.approve(fx.name, now: { S.date(2, 9) })
        #expect(await S.tick(fx, at: S.date(3, 4, 5))[fx.name]?.outcome == .reported)
        let report = fx.project.taskDirectory(fx.name).appendingPathComponent("reports/kept.md")
        try FileManager.default.createDirectory(at: report.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "# an old report\n".write(to: report, atomically: true, encoding: .utf8)
        let taskText = try String(contentsOf: fx.project.taskFileURL(fx.name), encoding: .utf8)
        let before = try fx.log.history()

        let after = try await fx.library.change(fx.name, .archive, now: { S.date(3, 12) })
        #expect(after.archived)

        // Off the active list, on the archived one; the other task is untouched.
        #expect(fx.library.activeNames() == [other.name])
        #expect(fx.library.archivedNames() == [fx.name])
        // Nothing was deleted: the definition, the report and every run are where they were, and it still loads.
        #expect(try String(contentsOf: fx.project.taskFileURL(fx.name), encoding: .utf8) == taskText)
        #expect(FileManager.default.fileExists(atPath: report.path))
        let history = try fx.log.history()
        #expect(history.runs == before.runs && history.approvedHash == before.approvedHash)
        let loaded = try fx.library.load(fx.name)
        #expect(loaded.definition.instructions == "Bump the next countries.")
        let summary = fx.library.summary(fx.name)
        #expect(summary.archived && summary.problem == nil && summary.lastOutcome == .reported)
    }

    @Test func archivedTaskDoesNotRun() async throws {
        let fx = try S.reportTask()
        try await fx.library.approve(fx.name, now: { S.date(2, 9) })
        try await fx.library.change(fx.name, .archive, now: { S.date(2, 10) })
        // Due many times over, it is never in a tick's plan, and a tick or a person asking for it records nothing.
        for day in 3...9 {
            let plan = TaskTick.plan(project: fx.project, now: S.date(day, 5), calendar: S.utc)
            #expect(plan.due.isEmpty && plan.broken.isEmpty)
            #expect(await S.tick(fx, at: S.date(day, 5)).isEmpty)
        }
        var runner = TaskRunner(
            project: fx.project, git: GitRunner(executable: URL(fileURLWithPath: "/usr/bin/false"), environment: [:]), gh: nil)
        runner.dryRun = true
        for trigger in [TaskTrigger.tick, .manual] {
            let result = await runner.run(fx.name, trigger: trigger)
            #expect(result.outcome == .skippedDisabled && !result.recorded)
            #expect(result.reason?.contains("archived") == true)
        }
        #expect(try fx.log.history().runs.isEmpty)
        #expect(fx.library.summary(fx.name).nextDue == nil)

        // Restored, it is enabled as it was before, and its schedule counts from the restore: the missed week is not owed.
        let restored = try await fx.library.change(fx.name, .restore, now: { S.date(9, 12) })
        #expect(!restored.archived && restored.enabled)
        #expect(fx.library.activeNames() == [fx.name] && fx.library.archivedNames().isEmpty)
        #expect(await S.tick(fx, at: S.date(9, 13)).isEmpty)
        #expect(await S.tick(fx, at: S.date(10, 4, 5))[fx.name]?.outcome == .reported)
    }

    @Test func aTaskDisabledWhenArchivedIsRestoredStillDisabled() async throws {
        let fx = try S.reportTask()
        try await fx.library.approve(fx.name, now: { S.date(2, 9) })
        try await fx.library.change(fx.name, .disable)
        try await fx.library.change(fx.name, .archive)
        let restored = try await fx.library.change(fx.name, .restore, now: { S.date(3, 12) })
        #expect(!restored.archived && !restored.enabled)
        let summary = fx.library.summary(fx.name)
        #expect(!summary.archived && !summary.enabled && summary.nextDue == nil)
        #expect(await S.tick(fx, at: S.date(5, 5)).isEmpty)
    }

    @Test func aTaskThatDoesNotLoadCanBeArchivedAndIsNotATickProblem() async throws {
        let fx = try TaskFixture(front: "at: 04:00\nfix: pr\npending: pending.sh")
        try fx.script("echo '[]'")
        try await fx.library.approve(fx.name, now: { S.date(2, 9) })
        try FileManager.default.removeItem(at: fx.project.root.appendingPathComponent("pending.sh"))
        #expect(TaskTick.plan(project: fx.project, now: S.date(3, 5), calendar: S.utc).broken.count == 1)
        try await fx.library.change(fx.name, .archive)
        #expect(TaskTick.plan(project: fx.project, now: S.date(3, 5), calendar: S.utc) == TaskTick.Plan(due: [], broken: []))
    }
}
