import Foundation
import Testing
import WorkbenchCore

@testable import WorkbenchApp

@MainActor @Suite struct TasksActionsTests {
    private func scenario() async throws -> (AppFixture, [String: String]) {
        let fixture = try await AppFixture(git: false)
        try await AppScenario.tasks.build(in: fixture)
        let probes = fixture.root.appendingPathComponent("probes")
        try FileManager.default.createDirectory(at: probes, withIntermediateDirectories: true)
        let env = [
            "WORKBENCH_APP_HOME": fixture.root.appendingPathComponent("home").path,
            "WORKBENCH_APP_LAUNCHCTL": "/nonexistent/launchctl", "WORKBENCH_APP_PROBES": probes.path,
        ]
        return (fixture, env)
    }

    private func model(_ env: [String: String], actions: TaskActions = .core) -> TasksModel {
        TasksModel(reader: .core(environment: env), actions: actions)
    }

    private func entry(_ model: TasksModel, _ name: String) throws -> TaskEntry {
        let shown = try #require(model.snapshot)
        return try #require(shown.entries.first { $0.id == name })
    }

    /// A run that records what it was asked and waits for the test to let it end.
    private final class FakeRun: @unchecked Sendable {
        private let lock = NSLock()
        private var started: [String] = []
        private var stopSwitch: TaskStopSwitch?
        private var continuation: CheckedContinuation<Void, Never>?
        var result = TaskRunResult(outcome: .reported, reason: "would take 1 unit: report", units: ["report"])
        var holds = false
        var calls: [String] { lock.withLock { started } }
        var stop: TaskStopSwitch? { lock.withLock { stopSwitch } }

        func run(_ name: String, _ stop: TaskStopSwitch, _ notice: @Sendable (String) -> Void) async -> TaskRunResult {
            lock.withLock {
                started.append(name)
                stopSwitch = stop
            }
            notice("working on \(name)")
            if holds { await withCheckedContinuation { continuation = $0 } }
            return result
        }

        func release() {
            let waiting = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                defer { continuation = nil }
                return continuation
            }
            waiting?.resume()
        }
    }

    private func fake(_ run: FakeRun) -> TaskActions {
        TaskActions(
            inspect: TaskActions.core.inspect, approve: TaskActions.core.approve,
            run: { _, name, stop, notice in await run.run(name, stop, notice) })
    }

    @Test func approveRecordsTheHash() async throws {
        let (fixture, env) = try await scenario()
        let tasks = model(env)
        await tasks.refresh(fixture.project)
        #expect(try entry(tasks, "cleanup-branches").summary.approval == .never)
        tasks.beginApprove(fixture.project, "cleanup-branches")
        #expect(tasks.approving?.name == "cleanup-branches")
        await tasks.confirmApprove(fixture.project)
        #expect(tasks.approving == nil)
        #expect(try entry(tasks, "cleanup-branches").summary.approval == .approved)
        let history = try TaskRunLog(project: fixture.project, name: "cleanup-branches").history()
        #expect(history.approvedHash == (try TaskLibrary(project: fixture.project).load("cleanup-branches")).hash)
    }

    @Test func approvalCardShowsTheTask() async throws {
        let (fixture, env) = try await scenario()
        let tasks = model(env)
        await tasks.refresh(fixture.project)
        tasks.beginApprove(fixture.project, "update-docs")
        let card = try #require(tasks.approving)
        let shown = Dictionary(uniqueKeysWithValues: card.settings.map { ($0.label, $0.value) })
        #expect(shown["when"] == "mon,thu 07:30")
        #expect(shown["budget"] == "$1.00 a run")
        #expect(shown["fix"]?.hasPrefix("report") == true)
        #expect(card.instructions == "Check the docs for stale pages.")
        #expect(tasks.selectedIsStale(fixture.project))
        // A task that does not load cannot be approved: no card, and the core says why.
        tasks.cancelApprove()
        tasks.beginApprove(fixture.project, "broken-task")
        #expect(tasks.approving == nil)
        #expect(tasks.actionNote?.contains("colour") == true)
        // A `fix: pr` task states its most it may cost.
        let sync = try TaskActions.core.inspect(fixture.project, "sync-fixtures")
        #expect(sync.cost == "up to $2.00 for the work and $0.50 to describe it: at most $2.50")
        // A task that sets no budget runs under the project's default, which is named when the config can be read; else unknown.
        let none = try TaskActions.core.inspect(fixture.project, "cleanup-branches")
        #expect(none.cost.hasPrefix("unknown"))
        try "default_budget_usd = 3\n\n[tools]\navailable = [\"Read\"]\n"
            .write(to: fixture.project.configURL, atomically: true, encoding: .utf8)
        let named = try TaskActions.core.inspect(fixture.project, "cleanup-branches")
        #expect(named.cost == "up to $3.00 for the report (the project's default budget)")
        // Codex reports no dollars: no cap in money is promised.
        try "default_budget_usd = 3\n\n[tools]\navailable = [\"Read\"]\n\n[agents.plan]\nprovider = \"codex\"\n"
            .write(to: fixture.project.configURL, atomically: true, encoding: .utf8)
        let codex = try TaskActions.core.inspect(fixture.project, "cleanup-branches")
        #expect(codex.cost.hasPrefix("no dollar cap: the report agent is Codex"))
    }

    @Test func approveRefusalStaysOpen() async throws {
        let (fixture, env) = try await scenario()
        let name = "scaffolded"
        let folder = fixture.project.taskFileURL(name).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "---\nfix: report\n---\n\(TaskScaffold.placeholder) say what to do\n"
            .write(to: fixture.project.taskFileURL(name), atomically: true, encoding: .utf8)
        let tasks = model(env)
        await tasks.refresh(fixture.project)
        tasks.beginApprove(fixture.project, name)
        await tasks.confirmApprove(fixture.project)
        #expect(tasks.approving != nil)
        #expect(tasks.approveError != nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.project.taskRunsURL(name).path))
        tasks.cancelApprove()
        #expect(tasks.approving == nil && tasks.approveError == nil)
    }

    /// Rewrites a task's file, as an editor would, and approves it again as the CLI would.
    private func edit(_ project: Project, _ name: String, _ text: String, approve: Bool = false) async throws {
        try text.write(to: project.taskFileURL(name), atomically: true, encoding: .utf8)
        if approve { try await TaskLibrary(project: project).approve(name) }
    }

    @Test func whatIsApprovedIsWhatWasShown() async throws {
        let (fixture, env) = try await scenario()
        let tasks = model(env)
        await tasks.refresh(fixture.project)
        tasks.beginApprove(fixture.project, "cleanup-branches")
        let shown = try #require(tasks.approving)
        // Edited in an editor while the card is open: the new text must not be approved unseen.
        try await edit(fixture.project, "cleanup-branches", "---\nat: 05:00\nfix: pr\nbudget: 9.00\n---\nDo something else.\n")
        await tasks.confirmApprove(fixture.project)
        #expect(tasks.approving != nil)
        #expect(tasks.approveError?.contains("edited after it was shown") == true)
        let history = try TaskRunLog(project: fixture.project, name: "cleanup-branches").history()
        #expect(history.approvedHash == nil)
        // Looking again shows the new version, and that one can be approved.
        tasks.cancelApprove()
        tasks.beginApprove(fixture.project, "cleanup-branches")
        #expect(tasks.approving?.hash != shown.hash)
        await tasks.confirmApprove(fixture.project)
        #expect(tasks.approving == nil)
    }

    @Test func aTaskChangedToPrAsksEvenIfTheListIsOld() async throws {
        let (fixture, env) = try await scenario()
        let run = FakeRun()
        let tasks = model(env, actions: fake(run))
        await tasks.refresh(fixture.project)
        let old = try entry(tasks, "weekly-report")
        #expect(old.summary.fix == .report)
        try await edit(
            fixture.project, "weekly-report", "---\nevery: 30d\nfix: pr\nbudget: 4.00\n---\nNow it opens pull requests.\n",
            approve: true)
        await tasks.beginRun(fixture.project, old, threadRunGoing: false)
        #expect(run.calls.isEmpty)
        #expect(tasks.confirmingRun?.cost == "up to $4.00 for the work and $0.50 to describe it: at most $4.50")
    }

    @Test func aRunStartsOnlyTheVersionTheCardNamed() async throws {
        let (fixture, env) = try await scenario()
        let run = FakeRun()
        let tasks = model(env, actions: fake(run))
        await tasks.refresh(fixture.project)
        await tasks.beginRun(fixture.project, try entry(tasks, "sync-fixtures"), threadRunGoing: false)
        #expect(tasks.confirmingRun?.cost.contains("$2.00") == true)
        // The budget is raised and approved again while the card is open.
        try await edit(
            fixture.project, "sync-fixtures", "---\nevery: 7d\nfix: pr\nbudget: 20.00\ntimeout: 20\n---\nRefresh the fixtures.\n",
            approve: true)
        await tasks.confirmRun(fixture.project)
        #expect(run.calls.isEmpty)
        #expect(tasks.actionNote?.contains("edited after the card was shown") == true)
    }

    @Test func aRunBelongsToItsProject() async throws {
        let (first, env) = try await scenario()
        let (second, _) = try await scenario()
        let run = FakeRun()
        run.holds = true
        let tasks = model(env, actions: fake(run))
        await tasks.refresh(first.project)
        let report = try entry(tasks, "weekly-report")
        let started = Task {
            await tasks.beginRun(first.project, report, threadRunGoing: false)
            await tasks.confirmRun(first.project)
        }
        while run.calls.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        try await Task.sleep(for: .milliseconds(30))
        // The other project has a task of the same name: it is not the one running, and has no result.
        #expect(tasks.isRunning("weekly-report", in: first.project))
        #expect(!tasks.isRunning("weekly-report", in: second.project))
        await tasks.refresh(second.project)
        run.release()
        await started.value
        #expect(tasks.result(of: "weekly-report", in: first.project)?.outcome == .reported)
        #expect(tasks.result(of: "weekly-report", in: second.project) == nil)
        // Finishing did not put the first project's tasks over the one on screen.
        #expect(tasks.snapshot(for: second.project) != nil)
        #expect(tasks.snapshot(for: first.project) == nil)
    }

    @Test func runNowAvailability() async throws {
        let (fixture, env) = try await scenario()
        let tasks = model(env)
        await tasks.refresh(fixture.project)
        func reason(_ name: String, thread: Bool = false) throws -> String? {
            tasks.runUnavailable(try entry(tasks, name), threadRunGoing: thread)
        }
        #expect(try reason("weekly-report") == nil)
        #expect(try reason("cleanup-branches")?.hasPrefix("Not approved") == true)
        #expect(try reason("update-docs")?.hasPrefix("Edited since") == true)
        #expect(try reason("broken-task")?.hasPrefix("The task does not load") == true)
        #expect(try reason("weekly-report", thread: true)?.contains("thread run is going") == true)
        // A run of the task going elsewhere (its log has an open run) is not started over.
        #expect(try reason("nightly-lint")?.contains("already going") == true)
    }

    @Test func aReportAsksFirstToo() async throws {
        // A report starts a read-only agent that spends: it names its cap, and cancelling starts nothing.
        let (fixture, env) = try await scenario()
        let run = FakeRun()
        let tasks = model(env, actions: fake(run))
        await tasks.refresh(fixture.project)
        await tasks.beginRun(fixture.project, try entry(tasks, "weekly-report"), threadRunGoing: false)
        #expect(run.calls.isEmpty)
        #expect(tasks.confirmingRun?.fix == .report && tasks.confirmingRun?.cost == "up to $1.00 for the report")
        tasks.cancelRun()
        #expect(run.calls.isEmpty)
        await tasks.beginRun(fixture.project, try entry(tasks, "weekly-report"), threadRunGoing: false)
        await tasks.confirmRun(fixture.project)
        #expect(run.calls == ["weekly-report"])
    }

    @Test func prRunAsksFirst() async throws {
        let (fixture, env) = try await scenario()
        let run = FakeRun()
        let tasks = model(env, actions: fake(run))
        await tasks.refresh(fixture.project)
        await tasks.beginRun(fixture.project, try entry(tasks, "sync-fixtures"), threadRunGoing: false)
        #expect(run.calls.isEmpty)
        #expect(tasks.confirmingRun?.name == "sync-fixtures")
        tasks.cancelRun()
        #expect(tasks.confirmingRun == nil && run.calls.isEmpty)
        await tasks.beginRun(fixture.project, try entry(tasks, "sync-fixtures"), threadRunGoing: false)
        await tasks.confirmRun(fixture.project)
        #expect(run.calls == ["sync-fixtures"])
        #expect(tasks.confirmingRun == nil)
    }

    @Test func aRunIsRecordedAndShown() async throws {
        let (fixture, env) = try await scenario()
        let run = FakeRun()
        run.holds = true
        let tasks = model(env, actions: fake(run))
        await tasks.refresh(fixture.project)
        let reads = tasks.reads
        let report = try entry(tasks, "weekly-report")
        let started = Task {
            await tasks.beginRun(fixture.project, report, threadRunGoing: false)
            await tasks.confirmRun(fixture.project)
        }
        while run.calls.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        try await Task.sleep(for: .milliseconds(30))
        #expect(tasks.runningTask == "weekly-report")
        #expect(tasks.runSaid == "working on weekly-report")
        run.release()
        await started.value
        #expect(tasks.runningTask == nil && tasks.runSaid == nil)
        #expect(tasks.lastResult?.task == "weekly-report")
        #expect(tasks.lastResult?.result.outcome == .reported)
        #expect(tasks.reads > reads, "the timeline is read again when the run ends")
    }

    @Test func stopStopsTheRun() async throws {
        let (fixture, env) = try await scenario()
        let run = FakeRun()
        run.holds = true
        let tasks = model(env, actions: fake(run))
        await tasks.refresh(fixture.project)
        let report = try entry(tasks, "weekly-report")
        let started = Task {
            await tasks.beginRun(fixture.project, report, threadRunGoing: false)
            await tasks.confirmRun(fixture.project)
        }
        while run.calls.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        try await Task.sleep(for: .milliseconds(30))
        #expect(run.stop?.isRequested == false)
        await tasks.stopRun()
        #expect(run.stop?.isRequested == true)
        run.result = TaskRunResult(outcome: .interrupted, reason: "stopped")
        run.release()
        await started.value
        #expect(tasks.lastResult?.result.outcome == .interrupted)
    }

    @Test func oneRunAtATime() async throws {
        let (fixture, env) = try await scenario()
        let run = FakeRun()
        run.holds = true
        let tasks = model(env, actions: fake(run))
        await tasks.refresh(fixture.project)
        let report = try entry(tasks, "weekly-report")
        let started = Task {
            await tasks.beginRun(fixture.project, report, threadRunGoing: false)
            await tasks.confirmRun(fixture.project)
        }
        while run.calls.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        try await Task.sleep(for: .milliseconds(30))
        let other = try entry(tasks, "bump-contract-details")
        #expect(tasks.runUnavailable(other, threadRunGoing: false)?.contains("is going from this window") == true)
        await tasks.beginRun(fixture.project, other, threadRunGoing: false)
        #expect(run.calls == ["weekly-report"])
        #expect(tasks.actionNote?.contains("going") == true)
        run.release()
        await started.value
    }

    @Test func aSkipIsNotAFailure() {
        for outcome in [TaskOutcome.skippedProjectBusy, .skippedAlreadyRunning, .skippedTooManyOpen] {
            #expect(TaskOutcomeStyle.tone(outcome) == .idle)
        }
        #expect(TaskOutcomeStyle.tone(.staleApproval) == .needsYou)
        #expect(TaskOutcomeStyle.tone(.failed) == .broken)
    }
}
