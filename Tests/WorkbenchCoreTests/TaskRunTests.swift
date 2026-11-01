import Foundation
import Testing

@testable import WorkbenchCore

/// A task in a project with a real repository, the fake claude and a fake gh.
private struct Run {
    let fx: RunnerFixture
    let task: TaskFixture
    let gh: FakeGH

    init(
        front: String = "fix: pr\nbatch: 2\npending: pending.sh", extraConfig: String = #"check_command = "true""#
    ) async throws {
        fx = try await RunnerFixture(extraConfig: extraConfig)
        task = try TaskFixture(in: fx.project, front: front)
        gh = try FakeGH(in: fx)
        try task.script(#"echo '[{"id":"ROU","title":"Romania"},{"id":"TUR","title":"Turkey"},{"id":"PAN","title":"Panama"}]'"#)
        try await task.library.approve(task.name)
    }

    func runner(_ directives: String...) -> TaskRunner {
        var runner = TaskRunner(project: fx.project, git: fx.git, gh: gh.runner)
        runner.runOptions = fx.options(directives.joined(separator: ","))
        runner.environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()]
        return runner
    }

    /// A runner for a `fix: report` task: `--dry`, or the read-only agent that answers it.
    func reporter(dry: Bool = false, agent: (any ReadOnlyAgent)? = nil) -> TaskRunner {
        var runner = runner()
        runner.dryRun = dry
        runner.readOnlyAgent = agent
        return runner
    }

    /// The fake claude's answers: the work (a line added to a.txt) and the description turn's JSON.
    func shippable() throws -> [String] {
        let answer = fx.repo.deletingLastPathComponent().appendingPathComponent("answer-\(UUID().uuidString).txt")
        try #"{"title": "chore: bump countries", "summary": "Bumps them.", "decisions": [], "deviations": []}"#
            .write(to: answer, atomically: true, encoding: .utf8)
        return ["write=a.txt", "answer=\(answer.path)"]
    }

    var reports: URL { fx.project.taskDirectory(task.name).appendingPathComponent("reports") }
    func reportFiles() -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: reports.path)) ?? []).sorted() }
    func ends() throws -> [Event] { try EventLogReader.read(at: task.log.url).events.filter { $0.kind == .taskRunEnded } }
    func threads() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: fx.project.threadsDirectory.path)) ?? []).sorted()
    }
}

@Suite(.processGate) struct TaskRunTests {
    @Test func aDryReportStartsNoThreadAndNoAgent() async throws {
        let run = try await Run(front: "fix: report\nbatch: 2\npending: pending.sh")
        let agent = ReportAgent(answer: "never asked")
        let result = await run.reporter(dry: true, agent: agent).run("bump", trigger: .manual)
        #expect(result.outcome == .reported && result.units == ["ROU", "TUR"] && result.thread == nil)
        #expect(result.reason == "dry run: would take ROU, TUR" && agent.requests.isEmpty)
        #expect(run.threads().isEmpty)
        let ended = try run.ends()
        #expect(ended.count == 1 && ended[0].data["outcome"]?.stringValue == "reported")
    }

    @Test func aReportAsksTheReadOnlyAgentAboutTheCommittedProjectAndKeepsTheAnswer() async throws {
        let run = try await Run(front: "fix: report\nbatch: 2\npending: pending.sh\nbudget: 0.75\ntimeout: 12")
        // What is committed is read; what is only on disk (a secret in the working tree) is not there for the agent to see.
        let untracked = run.fx.project.root.appendingPathComponent("untracked.txt")
        try "secret".write(to: untracked, atomically: true, encoding: .utf8)
        let agent = ReportAgent(answer: "# Three pages are stale\n\nThe details.")
        let result = await run.reporter(agent: agent).run("bump", trigger: .manual)
        #expect(result.outcome == .reported && result.units == ["ROU", "TUR"] && result.thread == nil)
        #expect(result.reason?.hasPrefix("Three pages are stale (.workbench/tasks/bump/reports/") == true)
        let request = try #require(agent.requests.first)
        #expect(request.tools == .read && request.budget == 0.75 && request.timeout == 720 && request.turn == "report")
        // The units reach the agent as data, in the prompt.
        #expect(request.prompt.contains("Romania") && request.prompt.contains("Turkey") && !request.prompt.contains("Panama"))
        #expect(agent.sawCommitted == true && agent.sawUntracked == false)
        #expect(!FileManager.default.fileExists(atPath: request.workingDirectory.path), "the checkout is removed after")
        let files = run.reportFiles()
        #expect(files.count == 1)
        let kept = try String(contentsOf: run.reports.appendingPathComponent(files[0]), encoding: .utf8)
        #expect(kept == "# Three pages are stale\n\nThe details.\n")
        let ended = try run.ends()
        #expect(run.threads().isEmpty && ended.count == 1)
    }

    @Test func aReportThatCannotBeAnsweredFailsAndKeepsNothing() async throws {
        let run = try await Run(front: "fix: report")
        let agent = ReportAgent(answer: nil, failure: "the budget ran out")
        let result = await run.reporter(agent: agent).run("bump", trigger: .manual)
        #expect(result.outcome == .failed && result.reason == "the budget ran out")
        #expect(run.reportFiles().isEmpty)
        let empty = await run.reporter(agent: ReportAgent(answer: "   \n")).run("bump", trigger: .manual)
        #expect(empty.outcome == .failed)
        let gone = ReportAgent(answer: nil, unavailable: "claude is not installed")
        let missing = await run.reporter(agent: gone).run("bump", trigger: .manual)
        #expect(missing.outcome == .failed && missing.reason == "claude is not installed")
    }

    @Test func aReportWhoseCheckoutCannotBeRemovedSaysSoEvenWhenItSucceeded() async throws {
        let run = try await Run(front: "fix: report")
        // The agent leaves a folder it cannot be removed from in the checkout: removal fails, the report still stands.
        let agent = ReportAgent(answer: "# Done", beforeAnswer: { dir in
            let locked = dir.appendingPathComponent("locked", isDirectory: true)
            try? FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
            try? "x".write(to: locked.appendingPathComponent("f"), atomically: true, encoding: .utf8)
            chmod(locked.path, 0o500)
        })
        let result = await run.reporter(agent: agent).run("bump", trigger: .manual)
        defer {
            let checkout = run.fx.project.taskDirectory("bump").appendingPathComponent("report/checkout/locked")
            chmod(checkout.path, 0o700)
        }
        #expect(result.outcome == .reported)
        let left = run.fx.project.taskDirectory("bump").appendingPathComponent("report/checkout")
        if FileManager.default.fileExists(atPath: left.path) { #expect(result.reason?.contains("could not be removed") == true) }
    }

    @Test func aHugeAnswerIsCutAndSaid() async throws {
        let run = try await Run(front: "fix: report")
        let huge = "# Big\n" + String(repeating: "x", count: TaskRunner.maxReportBytes + 5000)
        let result = await run.reporter(agent: ReportAgent(answer: huge)).run("bump", trigger: .manual)
        #expect(result.outcome == .reported && result.reason?.contains("the answer was cut at 256 KiB") == true)
        let name = try #require(run.reportFiles().first)
        let attributes = try FileManager.default.attributesOfItem(atPath: run.reports.appendingPathComponent(name).path)
        let size = try #require(attributes[.size] as? Int)
        #expect(size <= TaskRunner.maxReportBytes)
    }

    @Test func aReportIsNotSkippedForAnActiveThread() async throws {
        let run = try await Run(front: "fix: report")
        _ = try await ThreadService(project: run.fx.project, git: run.fx.git).newThread(name: "blocker")
        let result = await run.reporter(agent: ReportAgent(answer: "# fine")).run("bump", trigger: .manual)
        #expect(result.outcome == .reported)
    }

    @Test func anEmptyListIsNothingPendingAndSpendsNothing() async throws {
        let run = try await Run()
        try run.task.script("echo '[]'")
        try await run.task.library.approve("bump")
        let result = await run.runner().run("bump", trigger: .manual)
        #expect(result.outcome == .nothingPending && run.threads().isEmpty && result.isDone)
    }

    @Test func aTaskThatWasNeverApprovedOrChangedSinceDoesNotRun() async throws {
        let run = try await Run()
        try run.task.write(task: "---\nfix: pr\npending: pending.sh\n---\nDo something else.\n")
        let stale = await run.runner().run("bump", trigger: .manual)
        #expect(stale.outcome == .staleApproval && stale.reason?.contains("changed") == true)
        #expect(run.threads().isEmpty)

        let other = try TaskFixture(in: run.fx.project, name: "fresh", front: "fix: report")
        _ = other
        let never = await run.reporter(dry: true).run("fresh", trigger: .manual)
        #expect(never.outcome == .staleApproval && never.reason?.contains("never approved") == true)
    }

    @Test func aBusyProjectSkipsTheRunAndTouchesNothing() async throws {
        let run = try await Run()
        let active = try await run.fx.approvedThread()
        let result = await run.runner().run("bump", trigger: .tick)
        #expect(result.outcome == .skippedProjectBusy && result.reason?.contains(active) == true)
        #expect(run.threads() == [active])
        #expect(try run.ends().last?.data["outcome"]?.stringValue == "skipped-project-busy")
    }

    @Test func aRunWhileAnotherHoldsTheLogIsSkippedAndNotRecorded() async throws {
        let run = try await Run()
        let holder = try await run.task.log.openWriter()
        let result = await run.runner().run("bump", trigger: .manual)
        await holder.close()
        #expect(result.outcome == .skippedAlreadyRunning && !result.recorded)
        #expect(try run.task.log.history().runs.isEmpty)
    }

    @Test func aFailingPendingScriptEndsTheRunAsFailedWithItsReason() async throws {
        let run = try await Run()
        try run.task.script("echo broken >&2; exit 3")
        try await run.task.library.approve("bump")
        let result = await run.runner().run("bump", trigger: .manual)
        #expect(result.outcome == .failed && result.reason?.contains("exited with 3") == true)
        #expect(try run.ends().count == 1 && run.threads().isEmpty)
    }

    @Test func aPrTaskInAProjectWithNoCheckIsRefusedBeforeAnyWork() async throws {
        let run = try await Run(extraConfig: "")
        let result = await run.runner().run("bump", trigger: .manual)
        #expect(result.outcome == .failed && result.reason?.contains("no check configured") == true)
        #expect(run.threads().isEmpty)
    }

    @Test func aTaskThatCannotBePromptedEndsAsFailed() async throws {
        let run = try await Run(front: "fix: pr\ninputs: big.txt")
        try run.task.write("big.txt", String(repeating: "x", count: TaskFiles.maxInputBytes))
        try run.task.write("skill.md", String(repeating: "y", count: TaskFiles.maxIncludeBytes))
        try await run.task.library.approve("bump")
        // Within the limits of each file, and still under the prompt's own: this one runs. Over it, it is refused.
        let tooMuch = try await Run(front: "fix: pr\ninputs: [a.txt, b.txt, c.txt]")
        for name in ["a.txt", "b.txt", "c.txt"] { try tooMuch.task.write(name, String(repeating: "z", count: 30_000)) }
        try await tooMuch.task.library.approve("bump")
        let result = await tooMuch.runner().run("bump", trigger: .manual)
        #expect(result.outcome == .failed && result.reason?.contains("the limit is") == true)
        #expect(tooMuch.threads().isEmpty)
    }

    @Test func aFailedCheckLeavesTheThreadForAPersonAndShipsNothing() async throws {
        let run = try await Run(extraConfig: #"check_command = "false""#)
        let origin = try await addOrigin(run.fx)
        let result = await run.runner("write=a.txt").run("bump", trigger: .manual)
        #expect(result.outcome == .failed && result.reason?.contains("left for you") == true)
        let thread = try #require(result.thread)
        #expect(ThreadStore(project: run.fx.project).state(of: thread).decision == nil)
        #expect(try await originBranches(origin, run.fx) == ["refs/heads/main"])
        #expect(run.gh.count("pr create") == 0)
    }

    @Test func aPassingRunAcceptsAsTheTaskAndOpensOnePullRequest() async throws {
        let run = try await Run()
        let origin = try await addOrigin(run.fx)
        let result = await run.runner(try run.shippable().joined(separator: ",")).run("bump", trigger: .tick)
        #expect(result.outcome == .prOpened && result.units == ["ROU", "TUR"])
        #expect(result.pullRequest == "https://github.com/o/r/pull/12")
        let thread = try #require(result.thread)
        let events = try run.fx.events(thread)
        let accept = try #require(events.first { $0.kind == .reviewDecision })
        #expect(accept.data["decision"]?.stringValue == "accepted" && accept.data["by"]?.stringValue == "task:bump")
        #expect(events.contains { $0.kind == .prOpened })
        #expect(try await originBranches(origin, run.fx).contains("refs/heads/workbench/\(thread)"))
        #expect(run.gh.count("pr create") == 1)
    }

    @Test func unitsAreWorkedThroughAcrossRunsAndAClosedPullRequestBringsThemBack() async throws {
        // This is about running out of units, not about waiting for review: the limit is out of the way.
        let run = try await Run(front: "fix: pr\nbatch: 2\nmax_open: 10\npending: pending.sh")
        _ = try await addOrigin(run.fx)
        let directives = try run.shippable().joined(separator: ",")
        let first = await run.runner(directives).run("bump", trigger: .tick)
        #expect(first.units == ["ROU", "TUR"])

        try run.gh.put("list", #"[{"state":"OPEN"}]"#)
        let second = await run.runner(directives).run("bump", trigger: .tick)
        #expect(second.outcome == .prOpened && second.units == ["PAN"])
        let third = await run.runner(directives).run("bump", trigger: .tick)
        #expect(third.outcome == .nothingPending)

        // The first pull request was closed unmerged: its two units are offered again.
        try run.gh.put("list", #"[{"state":"CLOSED"}]"#)
        let fourth = await run.runner(directives).run("bump", trigger: .tick)
        #expect(fourth.outcome == .prOpened && fourth.units == ["ROU", "TUR"])
        let outcomes = try run.ends().map { $0.data["outcome"]?.stringValue }
        #expect(outcomes == ["pr-opened", "pr-opened", "nothing-pending", "pr-opened"])
    }

    @Test func noPullRequestIsOpenedWhenTheChangeCannotBeDescribed() async throws {
        let run = try await Run()
        let origin = try await addOrigin(run.fx)
        // The fake claude answers the describing turn with something that is not a description.
        let result = await run.runner("write=a.txt").run("bump", trigger: .manual)
        #expect(result.outcome == .failed && result.reason?.contains("could not be described") == true)
        let thread = try #require(result.thread)
        #expect(ThreadStore(project: run.fx.project).state(of: thread).decision == "accepted")
        #expect(try await originBranches(origin, run.fx) == ["refs/heads/main"])
        #expect(run.gh.count("pr create") == 0)
    }

    @Test func aRunThatDiedAfterOpeningItsPullRequestDoesNotOpenAnotherForTheSameUnits() async throws {
        let run = try await Run()
        _ = try await addOrigin(run.fx)
        // Dies after the pull request is open and before the end is written: only the thread event is on record.
        let dead = try await run.task.log.openWriter()
        try await dead.append(.taskRunStarted, data: ["trigger": "tick"])
        try await dead.append(.taskRunThread, data: ["thread": "g-1-bump-ROU-TUR", "units": ["ROU", "TUR"]])
        await dead.close()
        try run.gh.put("list", #"[{"state":"OPEN"}]"#)
        let result = await run.runner(try run.shippable().joined(separator: ",")).run("bump", trigger: .tick)
        #expect(result.outcome == .prOpened && result.units == ["PAN"])
        let history = try run.task.log.history()
        #expect(history.runs.first?.outcome == .interrupted && history.runs.first?.units == ["ROU", "TUR"])
    }

    @Test func aRunThatDiedBeforeAnyPullRequestExistedOffersItsUnitsAgain() async throws {
        let run = try await Run()
        _ = try await addOrigin(run.fx)
        let dead = try await run.task.log.openWriter()
        try await dead.append(.taskRunStarted, data: ["trigger": "tick"])
        try await dead.append(.taskRunThread, data: ["thread": "g-1-bump-ROU-TUR", "units": ["ROU", "TUR"]])
        await dead.close()
        // GitHub answers, and has no pull request for that branch: the units are offered again, after the one not tried yet.
        let result = await run.runner(try run.shippable().joined(separator: ",")).run("bump", trigger: .tick)
        #expect(result.outcome == .prOpened && result.units == ["PAN", "ROU"])
    }

    @Test func theThreadIsOnRecordBeforeTheTurnStarts() async throws {
        let run = try await Run(extraConfig: #"check_command = "false""#)
        let result = await run.runner("write=a.txt").run("bump", trigger: .manual)
        let kinds = try EventLogReader.read(at: run.task.log.url).events.map(\.kind.rawValue)
        #expect(kinds == ["task.approved", "task.run.started", "task.run.thread", "task.run.ended"])
        #expect(try run.task.log.history().runs.first?.thread == result.thread)
    }

    @Test func aFailedRunWhoseThreadAPersonShippedByHandIsNotDoneAgain() async throws {
        let run = try await Run()
        _ = try await addOrigin(run.fx)
        // The change cannot be described, so the thread is accepted and left for `workbench ship`.
        let first = await run.runner("write=a.txt").run("bump", trigger: .tick)
        #expect(first.outcome == .failed && first.units == ["ROU", "TUR"])
        // The person ships it: its branch now has an open pull request.
        try run.gh.put("list", #"[{"state":"OPEN"}]"#)
        let second = await run.runner(try run.shippable().joined(separator: ",")).run("bump", trigger: .tick)
        #expect(second.outcome == .prOpened && second.units == ["PAN"])
    }

    @Test func theThreadEventCarriesTheApprovalTheRunRanUnder() async throws {
        let run = try await Run(extraConfig: #"check_command = "false""#)
        _ = await run.runner("write=a.txt").run("bump", trigger: .manual)
        let history = try run.task.log.history()
        let event = try #require(
            EventLogReader.read(at: run.task.log.url).events.first { $0.kind == .taskRunThread })
        #expect(event.data["hash"]?.stringValue == history.approvedHash)
    }

    @Test func aTaskThatChangesNothingIsNothingToDoAndLeavesNoThreadBehind() async throws {
        let run = try await Run(front: "fix: pr")
        try await run.task.library.approve("bump")
        // No `write=`: the agent finds nothing to change, the check passes, and there is nothing to accept.
        let result = await run.runner().run("bump", trigger: .tick)
        #expect(result.outcome == .nothingToDo && result.isDone && result.thread != nil)
        #expect(ThreadStore(project: run.fx.project).activeThreadID() == nil)
        let again = await run.runner().run("bump", trigger: .tick)
        #expect(again.outcome != .skippedProjectBusy)
    }

    @Test func aRunLeftOpenByADeadProcessIsClosedByTheNextRun() async throws {
        let run = try await Run(front: "fix: report")
        let dead = try await run.task.log.openWriter()
        try await dead.append(.taskRunStarted, data: ["trigger": "tick"])
        await dead.close()
        let result = await run.reporter(dry: true).run("bump", trigger: .tick)
        #expect(result.outcome == .reported)
        let history = try run.task.log.history()
        #expect(history.runs.map(\.outcome) == [.interrupted, .reported] && history.openRun == nil)
    }
}

/// A read-only agent that answers a report turn from a stub, and writes down what it was asked and what it could see.
private final class ReportAgent: ReadOnlyAgent, @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [ReadOnlyRequest] = []
    private(set) var sawCommitted: Bool?
    private(set) var sawUntracked: Bool?
    let answer: String?
    let failure: String?
    let notAvailable: String?

    let beforeAnswer: (@Sendable (URL) -> Void)?

    init(
        answer: String?, failure: String? = nil, unavailable: String? = nil, beforeAnswer: (@Sendable (URL) -> Void)? = nil
    ) {
        (self.answer, self.failure, notAvailable, self.beforeAnswer) = (answer, failure, unavailable, beforeAnswer)
    }

    var requests: [ReadOnlyRequest] { lock.withLock { asked } }
    func unavailable() -> String? { notAvailable }
    func shownArguments(for request: ReadOnlyRequest) -> [String] { ["stub"] }
    func run(_ request: ReadOnlyRequest, attach: @Sendable (ProcessRun) -> Void) async -> ReadOnlyAnswer {
        lock.withLock {
            asked.append(request)
            sawCommitted = FileManager.default.fileExists(atPath: request.workingDirectory.appendingPathComponent("a.txt").path)
            let stray = request.workingDirectory.appendingPathComponent("untracked.txt")
            sawUntracked = FileManager.default.fileExists(atPath: stray.path)
        }
        beforeAnswer?(request.workingDirectory)
        return ReadOnlyAnswer(text: answer, costUSD: nil, failure: failure)
    }
}
