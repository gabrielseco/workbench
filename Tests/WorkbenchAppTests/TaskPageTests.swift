import Foundation
import Testing
import WorkbenchCore

@testable import WorkbenchApp

@MainActor private var keptTaskPageFixtures: [AppFixture] = []

/// The task page (design parity 5): its header, its own *Will it run tonight?*, its runs by day and the button each has.
@MainActor @Suite struct TaskPageTests {
    private let now = Date(timeIntervalSince1970: 1_793_500_000)

    private func snapshot() async throws -> TasksSnapshot {
        let fixture = try await AppFixture(git: false)
        keptTaskPageFixtures.append(fixture)
        try await AppScenario.tasks.build(in: fixture)
        let probes = fixture.root.appendingPathComponent("probes")
        try FileManager.default.createDirectory(at: probes, withIntermediateDirectories: true)
        let answers = [
            ("sched", "Repeating power events:\n"), ("power", "Now drawing from 'AC Power'\n"),
            ("filevault", "FileVault is On.\n"),
        ]
        for (name, text) in answers { try text.write(to: probes.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        let env = [
            "WORKBENCH_APP_HOME": fixture.root.appendingPathComponent("home").path,
            "WORKBENCH_APP_LAUNCHCTL": "/nonexistent/launchctl", "WORKBENCH_APP_PROBES": probes.path,
        ]
        return try await TasksReader.core(environment: env).read(fixture.project, now)
    }

    private func entry(_ name: String) async throws -> TaskEntry {
        try #require(try await snapshot().entries.first { $0.id == name })
    }

    private let clean = TimerCard.lines([TimerStatusLine(level: .ok, text: "launchd job installed")])

    // MARK: Header

    @Test func theHeaderSaysTheScheduleWhatItDoesItsRunsAndWhereItIsDefined() async throws {
        let bump = try await entry("bump-contract-details")
        let header = TaskPage.header(bump, now: now)
        #expect(header.line.hasPrefix("weekdays 04:00 · ") && header.line.contains("· \(bump.runs.count) run"))
        #expect(header.line.contains("opens a PR") || header.line.contains("reports"))
        #expect(header.path == ".workbench/tasks/bump-contract-details/task.md")
        let report = TaskPage.header(try await entry("weekly-report"), now: now)
        #expect(report.line.hasPrefix("every 30d · ") && report.line.contains("next "), "\(report.line)")
        #expect(TaskPage.header(try await entry("broken-task"), now: now).line.hasPrefix("manual · "), "no schedule is manual")
        var one = bump
        one.runs = Array(bump.runs.prefix(1))
        #expect(TaskPage.header(one, now: now).line.contains("· 1 run ·"), "one run is not runs")
    }

    // MARK: Will it run tonight

    @Test func eachTaskStateHasItsVerdictAndItsWarningsWorstFirst() async throws {
        let none: String? = nil
        let broken = RunTonight.derive(try await entry("broken-task"), timer: clean, activeThread: none)
        #expect(broken.verdict == .willNotRun && broken.warnings.first?.text == "The task does not load.")

        let notApproved = RunTonight.derive(try await entry("cleanup-branches"), timer: clean, activeThread: none)
        #expect(notApproved.verdict == .willNotRun)
        #expect(notApproved.warnings.first?.action == .approve)
        #expect(notApproved.warnings.first?.detail == "workbench task approve cleanup-branches")

        let stale = RunTonight.derive(try await entry("update-docs"), timer: clean, activeThread: none)
        #expect(stale.verdict == .willNotRun && stale.warnings.first?.action == .reapprove)

        let reported = RunTonight.derive(try await entry("weekly-report"), timer: clean, activeThread: none)
        #expect(reported.verdict == .willRun && reported.warnings.isEmpty && !reported.openByDefault && reported.countText == nil)
    }

    @Test func anActiveThreadAndTheTimersLinesAreWarningsAndAProblemComesBeforeAWarning() async throws {
        let weekly = try await entry("weekly-report")
        let timer = TimerCard.lines([
            TimerStatusLine(level: .warn, text: "On battery power"), TimerStatusLine(level: .fail, text: "launchd job missing"),
            TimerStatusLine(level: .ok, text: "FileVault is on"),
        ])
        let tonight = RunTonight.derive(weekly, timer: timer, activeThread: "g-2026-11-03-x")
        #expect(tonight.verdict == .willNotRun, "the timer failing stops it too")
        #expect(
            tonight.warnings.map(\.text) == [
                "launchd job missing", "An earlier thread is still active, so the next run would skip.", "On battery power",
            ], "problems first, then the project's, then the machine's warnings")
        #expect(tonight.warnings[1].action == .openThread("g-2026-11-03-x"))
        #expect(tonight.countText == "3 warnings" && tonight.openByDefault)
        let one = RunTonight.derive(weekly, timer: TimerCard.lines([TimerStatusLine(level: .warn, text: "w")]), activeThread: nil)
        #expect(one.verdict == .checkWarnings && one.countText == "1 warning")
    }

    @Test func aTaskThatWaitsForReviewSaysSo() async throws {
        let bump = try await entry("bump-contract-details")
        #expect(bump.runs.first?.outcome == .skippedTooManyOpen)
        let tonight = RunTonight.derive(bump, timer: clean, activeThread: nil)
        #expect(tonight.verdict == .checkWarnings)
        #expect(tonight.warnings.map(\.text) == ["It has as many pull requests open as it allows: it waits for review."])
    }

    @Test func theCardsButtonsAreTheOnesTheWarningsAskFor() {
        func button(_ action: RunTonight.Action?) -> RunAction? {
            RunTonightCard.action(for: RunTonight.Warning(fails: true, text: "w", detail: nil, action: action))
        }
        #expect(button(.approve) == .approve && button(.approve)?.title == "Approve…", "first approval is not a re-approval")
        #expect(button(.reapprove) == .reapprove && button(.openThread("t")) == .openThread("t") && button(nil) == nil)
    }

    @Test func theTimersLinesAboutTasksAreNotAnotherTasksWarnings() async throws {
        let timer = TimerCard.lines([
            TimerStatusLine(level: .fail, text: "task broken-task: cannot be loaded: line 3"),
            TimerStatusLine(level: .warn, text: "task weekly-report: STALE: workbench task approve weekly-report"),
            TimerStatusLine(level: .warn, text: "wake: no repeating wake is set"),
        ])
        let tonight = RunTonight.derive(try await entry("weekly-report"), timer: timer, activeThread: nil)
        #expect(tonight.warnings.map(\.text) == ["wake: no repeating wake is set"], "only the machine's line")
        #expect(tonight.verdict == .checkWarnings)
    }

    @Test func aTaskThatIsRunningDoesNotWarnAboutTheThreadItIsRunningIn() async throws {
        let running = try await entry("nightly-lint")
        #expect(running.isRunning)
        #expect(RunTonight.derive(running, timer: clean, activeThread: "g-x").warnings.isEmpty)
    }

    @Test func aTimerThatCannotBeReadIsAWarningAndNeverAGreen() async throws {
        let weekly = try await entry("weekly-report")
        let tonight = RunTonight.derive(weekly, timer: .unknown("launchctl did not answer"), activeThread: nil)
        #expect(tonight.verdict == .checkWarnings)
        #expect(tonight.warnings.first?.text == "The timer could not be read: launchctl did not answer")
    }

    // MARK: Runs by day

    private func run(_ date: Date, outcome: TaskOutcome? = .reported, thread: String? = nil) -> TaskHistory.Run {
        TaskHistory.Run(
            started: date, ended: date, pullRequest: nil, trigger: "tick", outcome: outcome, reason: nil, units: [],
            thread: thread)
    }

    @Test func runsAreGroupedUnderTodayYesterdayAndTheDateNewestFirst() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let noon = Date(timeIntervalSince1970: 1_793_534_400)
        let runs = [
            run(noon.addingTimeInterval(-3_600)), run(noon.addingTimeInterval(-7_200)), run(noon.addingTimeInterval(-86_400)),
            run(noon.addingTimeInterval(-3 * 86_400)),
        ]
        let groups = RunDay.groups(runs: runs, now: noon, calendar: calendar)
        #expect(groups.map(\.heading).prefix(2) == ["TODAY", "YESTERDAY"])
        #expect(groups.map { $0.runs.count } == [2, 1, 1])
        #expect(groups.last?.heading != "TODAY" && groups.last?.heading != "YESTERDAY")
        #expect(RunDay.groups(runs: [], now: noon, calendar: calendar).isEmpty)
    }

    // MARK: The button a run has

    @Test func eachRunHasTheOneButtonThatDealsWithHowItEnded() {
        let date = now
        #expect(RunAction.of(run(date, outcome: .failed)) == .viewLog)
        #expect(RunAction.of(run(date, outcome: .failed, thread: "t")) == .viewLog, "its log before its thread")
        #expect(RunAction.of(run(date, outcome: .budgetExceeded)) == .viewLog)
        #expect(RunAction.of(run(date, outcome: .interrupted)) == .viewLog)
        #expect(RunAction.of(run(date, outcome: .staleApproval)) == .reapprove)
        #expect(RunAction.of(run(date, outcome: .prOpened, thread: "t")) == .openThread("t"))
        #expect(RunAction.of(run(date, outcome: .skippedProjectBusy, thread: "t")) == .openThread("t"))
        #expect(RunAction.of(run(date, outcome: .nothingPending)) == nil, "nothing behind it, no button")
        #expect(RunAction.of(run(date, outcome: nil, thread: "t")) == nil, "a run still going has none")
        #expect(RunAction.viewLog.title == "View log" && RunAction.reapprove.title == "Re-approve")
        #expect(RunAction.openThread("t").title == "Open thread")
    }

    // MARK: The snapshot

    @Test func theSnapshotKnowsTheActiveThreadOnlyWhileOneIsOpen() async throws {
        #expect(try await snapshot().activeThread == "invoice-pagination", "the tasks fixture's own open thread")
        let fixture = try await AppFixture()
        keptTaskPageFixtures.append(fixture)
        try await fixture.addThread("t1")
        let read = try await TasksReader.core().read(fixture.project, now)
        #expect(read.activeThread == "t1")
        try fixture.decide("t1", "accepted")
        let after = try await TasksReader.core().read(fixture.project, now)
        #expect(after.activeThread == nil)
    }
}
