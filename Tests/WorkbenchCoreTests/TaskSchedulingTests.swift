import Foundation
import Testing

@testable import WorkbenchCore

/// Disabling a task: the schedule is off until it is enabled again, and that is on disk, so a new process (the app relaunched, the
/// timer's next `task tick`) reads it the same way.
@Suite(.processGate) struct TaskSchedulingTests {
    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }()

    /// 2026-11-02 is a Monday.
    static func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        let parts = DateComponents(
            calendar: utc, timeZone: utc.timeZone, year: 2026, month: 11, day: day, hour: hour, minute: minute)
        return utc.date(from: parts) ?? .distantPast
    }

    /// A tick as the timer runs it, from nothing in memory: a fresh plan read from disk, then each due task through the runner.
    static func tick(_ fx: TaskFixture, at now: Date) async -> [String: TaskRunResult] {
        var runner = TaskRunner(
            project: fx.project, git: GitRunner(executable: URL(fileURLWithPath: "/usr/bin/false"), environment: [:]), gh: nil)
        runner.now = { now }
        runner.dryRun = true
        runner.environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()]
        var results: [String: TaskRunResult] = [:]
        for name in TaskTick.plan(project: fx.project, now: now, calendar: utc).due {
            results[name] = await runner.run(name, trigger: .tick)
        }
        return results
    }

    static func reportTask() throws -> TaskFixture {
        let fx = try TaskFixture(front: "at: 04:00\nfix: report\npending: pending.sh")
        try fx.script(#"echo '[{"id":"a"}]'"#)
        return fx
    }

    @Test func disabledTaskDoesNotRunUntilReenabled() async throws {
        let fx = try Self.reportTask()
        try await fx.library.approve(fx.name, now: { Self.date(2, 9) })
        // It runs on its schedule while enabled.
        #expect(await Self.tick(fx, at: Self.date(3, 4, 5))[fx.name]?.outcome == .reported)
        let runsBefore = try fx.log.history().runs.count

        let disabled = try await fx.library.change(fx.name, .disable, now: { Self.date(3, 12) })
        #expect(!disabled.enabled && !disabled.archived)
        // Days of slots pass: nothing is due and nothing runs, and the task is not reported as a problem either.
        for day in 4...9 {
            let plan = TaskTick.plan(project: fx.project, now: Self.date(day, 5), calendar: Self.utc)
            #expect(plan.due.isEmpty && plan.broken.isEmpty)
            #expect(await Self.tick(fx, at: Self.date(day, 5)).isEmpty)
        }
        // The state is in the run log, not in memory: a new library and log (the app or the timer started again) read it the same.
        let reread = try TaskRunLog(project: Project(root: fx.project.root), name: fx.name).history()
        #expect(!reread.enabled)
        let summary = TaskLibrary(project: Project(root: fx.project.root)).summary(fx.name, now: Self.date(9, 5), calendar: Self.utc)
        #expect(!summary.enabled && summary.nextDue == nil)
        #expect(try fx.log.history().runs.count == runsBefore)

        // A tick that was planned before the task was turned off finds it off when it runs, and records nothing.
        var runner = TaskRunner(
            project: fx.project, git: GitRunner(executable: URL(fileURLWithPath: "/usr/bin/false"), environment: [:]), gh: nil)
        runner.dryRun = true
        let late = await runner.run(fx.name, trigger: .tick)
        #expect(late.outcome == .skippedDisabled && !late.recorded)
        #expect(try fx.log.history().runs.count == runsBefore)

        // Enabled on Monday at noon: the schedule counts from then, so the week it missed is not made up at once.
        let enabled = try await fx.library.change(fx.name, .enable, now: { Self.date(9, 12) })
        #expect(enabled.enabled)
        #expect(await Self.tick(fx, at: Self.date(9, 13)).isEmpty)
        #expect(
            TaskLibrary(project: fx.project).summary(fx.name, now: Self.date(9, 13), calendar: Self.utc).nextDue
                == Self.date(10, 4))
        #expect(await Self.tick(fx, at: Self.date(10, 4, 5))[fx.name]?.outcome == .reported)
        #expect(try fx.log.history().runs.count == runsBefore + 1)
    }

    @Test func aDisabledTaskStillRunsWhenAPersonAsks() async throws {
        let fx = try Self.reportTask()
        try await fx.library.approve(fx.name, now: { Self.date(2, 9) })
        try await fx.library.change(fx.name, .disable)
        var runner = TaskRunner(
            project: fx.project, git: GitRunner(executable: URL(fileURLWithPath: "/usr/bin/false"), environment: [:]), gh: nil)
        runner.dryRun = true
        runner.environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()]
        #expect(await runner.run(fx.name, trigger: .manual).outcome == .reported)
        #expect(!(try fx.log.history().enabled), "a run by hand does not turn the schedule back on")
    }

    @Test func disablingTwiceWritesOneEventAndEnablingAnEnabledTaskWritesNone() async throws {
        let fx = try Self.reportTask()
        try await fx.library.change(fx.name, .enable)
        try await fx.library.change(fx.name, .disable)
        try await fx.library.change(fx.name, .disable)
        let kinds = try EventLogReader.read(at: fx.log.url).events.map(\.kind)
        #expect(kinds == [.taskDisabled])
    }

    @Test func aChangeIsRefusedWhileARunHoldsTheLogAndForNoSuchTask() async throws {
        let fx = try Self.reportTask()
        let writer = try await fx.log.openWriter()
        await #expect(throws: TaskStateError.running(fx.name)) { try await fx.library.change(fx.name, .disable) }
        await writer.close()
        await #expect(throws: TaskStateError.notFound("nope")) { try await fx.library.change("nope", .disable) }
        #expect(try fx.log.history().enabled)
    }
}
