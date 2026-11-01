import Foundation
import Testing

@testable import WorkbenchCore

/// A task with four units in a project with a real repository, the fake claude, a fake gh and an origin.
private struct Safe {
    let fx: RunnerFixture
    let task: TaskFixture
    let gh: FakeGH
    let marker: URL

    init(
        front: String = "fix: pr\nbatch: 1\npending: pending.sh", extraConfig: String = #"check_command = "true""#
    ) async throws {
        fx = try await RunnerFixture(extraConfig: extraConfig)
        task = try TaskFixture(in: fx.project, front: front)
        gh = try FakeGH(in: fx)
        marker = fx.project.root.appendingPathComponent("pending-ran.txt")
        // Each run of the script leaves a line, so a run that never got as far as the script is told by its absence.
        let units = #"[{"id":"ROU"},{"id":"TUR"},{"id":"PAN"},{"id":"PRI"}]"#
        try task.script("echo ran >> pending-ran.txt\necho '\(units)'")
        try await task.library.approve(task.name)
        _ = try await addOrigin(fx)
    }

    var scriptRuns: Int { ((try? String(contentsOf: marker, encoding: .utf8)) ?? "").split(separator: "\n").count }

    func run(_ directives: String..., gh override: GitRunner?? = nil) async throws -> TaskRunResult {
        var runner = TaskRunner(project: fx.project, git: fx.git, gh: override ?? gh.runner)
        runner.runOptions = fx.options(directives.joined(separator: ","))
        runner.environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()]
        return await runner.run(task.name, trigger: .tick)
    }

    /// The fake claude's work and the description turn's answer.
    func shippable() throws -> String {
        let answer = fx.repo.deletingLastPathComponent().appendingPathComponent("answer-\(UUID().uuidString).txt")
        try #"{"title": "chore: bump", "summary": "Bumps it.", "decisions": [], "deviations": []}"#
            .write(to: answer, atomically: true, encoding: .utf8)
        return "write=a.txt,answer=\(answer.path)"
    }

    func threads() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: fx.project.threadsDirectory.path)) ?? []).sorted()
    }
}

@Suite(.processGate) struct TaskSafetyTests {
    @Test func aTaskWaitsForReviewOnceItsPullRequestsAreAtTheLimit() async throws {
        let safe = try await Safe()
        let work = try safe.shippable()
        let first = try await safe.run(work)
        try safe.gh.put("list", #"[{"state":"OPEN"}]"#)
        let second = try await safe.run(work)
        #expect(first.outcome == .prOpened && second.outcome == .prOpened)
        let (threadsBefore, scriptBefore) = (safe.threads().count, safe.scriptRuns)

        let third = try await safe.run(work)
        #expect(third.outcome == .skippedTooManyOpen && !third.isDone)
        #expect(third.reason?.contains("2 of the task's pull requests are still open (max_open 2)") == true)
        #expect(third.reason?.contains("pull/12") == true)
        // It did not get as far as a thread, the script or the agent.
        #expect(safe.threads().count == threadsBefore && safe.scriptRuns == scriptBefore && third.thread == nil)
        #expect(try safe.task.log.history().lastRun?.outcome == .skippedTooManyOpen)
    }

    @Test func aRunThatDiedAfterPublishingStillCountsAsAnOpenPullRequest() async throws {
        let safe = try await Safe(front: "fix: pr\nbatch: 1\nmax_open: 1\npending: pending.sh")
        // Dies after the pull request is published and before its end is written: only the thread is on record.
        let dead = try await safe.task.log.openWriter()
        try await dead.append(.taskRunStarted, data: ["trigger": "tick"])
        try await dead.append(.taskRunThread, data: ["thread": "g-1-bump-ROU", "units": ["ROU"]])
        await dead.close()
        try safe.gh.put("list", #"[{"state":"OPEN"}]"#)
        let result = try await safe.run(try safe.shippable())
        #expect(result.outcome == .skippedTooManyOpen)
        #expect(result.reason?.contains("branch workbench/g-1-bump-ROU") == true)
        #expect(try safe.task.log.history().runs.first?.outcome == .interrupted)
        // GitHub says that branch has no pull request after all: the run goes ahead.
        try safe.gh.put("list", "[]")
        #expect(try await safe.run(try safe.shippable()).outcome == .prOpened)
    }

    @Test func aThreadThatCannotBeDiscardedIsSaidNotClaimed() async throws {
        let safe = try await Safe()
        var runner = TaskRunner(project: safe.fx.project, git: safe.fx.git, gh: safe.gh.runner)
        runner.notice = { _ in }
        let service = ThreadService(project: safe.fx.project, git: safe.fx.git)
        #expect(TaskRunner.notDiscarded("g-x") == "thread g-x could not be removed and is left for you (workbench abandon)")
        let id = try await service.newThread(name: "tmp", base: "main")
        #expect(await runner.discard(id, service: service))
        #expect(ThreadStore(project: safe.fx.project).activeThreadID() == nil)
        // The service refuses a thread that has already ended: that is a discard that did not happen, and it says so.
        #expect(await runner.discard(id, service: service) == false)
    }

    @Test func aMergedOrClosedPullRequestNoLongerCounts() async throws {
        for state in ["MERGED", "CLOSED"] {
            let safe = try await Safe()
            let work = try safe.shippable()
            _ = try await safe.run(work)
            try safe.gh.put("list", #"[{"state":"OPEN"}]"#)
            _ = try await safe.run(work)
            try safe.gh.put("list", "[{\"state\":\"\(state)\"}]")
            let next = try await safe.run(work)
            #expect(next.outcome != .skippedTooManyOpen, "\(state): \(next.reason ?? "")")
        }
    }

    @Test func theLimitIsTheTasksOwnToSet() async throws {
        let safe = try await Safe(front: "fix: pr\nbatch: 1\nmax_open: 3\npending: pending.sh")
        let work = try safe.shippable()
        _ = try await safe.run(work)
        try safe.gh.put("list", #"[{"state":"OPEN"}]"#)
        let outcomes = [try await safe.run(work), try await safe.run(work), try await safe.run(work)].map(\.outcome)
        #expect(outcomes == [.prOpened, .prOpened, .skippedTooManyOpen])
    }

    @Test func whenGitHubCannotBeAskedTheRunIsSkippedNotGuessed() async throws {
        let safe = try await Safe()
        let work = try safe.shippable()
        _ = try await safe.run(work)
        try safe.gh.put("list", #"[{"state":"OPEN"}]"#)
        _ = try await safe.run(work)
        let blind = try await safe.run(work, gh: .some(nil))
        #expect(blind.outcome == .skippedTooManyOpen)
        #expect(blind.reason?.contains("cannot tell whether the task's earlier pull requests are still open") == true)
    }

    @Test func aTaskThatNeverOpenedAPullRequestHasNothingToCount() async throws {
        let safe = try await Safe()
        let blind = try await safe.run("write=a.txt", gh: .some(nil))
        #expect(blind.outcome != .skippedTooManyOpen)
    }

    @Test func aDryRunTaskIsNotLimited() async throws {
        let safe = try await Safe(front: "fix: report\nbatch: 1\nmax_open: 1\npending: pending.sh")
        let results = [try await safe.run(), try await safe.run(), try await safe.run()]
        #expect(results.allSatisfy { $0.outcome == .reported })
    }

    @Test func aSetupThatFailsBeforeAnyTurnLeavesNoThreadBehind() async throws {
        let safe = try await Safe(extraConfig: "check_command = \"true\"\nsetup_command = \"false\"")
        let first = try await safe.run("write=a.txt")
        #expect(first.outcome == .failed)
        #expect(first.reason?.contains("no turn had started, so the thread was discarded") == true)
        #expect(ThreadStore(project: safe.fx.project).activeThreadID() == nil)
        // The next run is not skipped for a dead thread: it tries, and fails the same way.
        let second = try await safe.run("write=a.txt")
        #expect(second.outcome == .failed)
    }

    @Test func aThreadThatRanATurnIsStillLeftForAPerson() async throws {
        let safe = try await Safe(extraConfig: #"check_command = "false""#)
        let result = try await safe.run("write=a.txt")
        #expect(result.outcome == .failed && result.reason?.contains("left for you") == true)
        #expect(ThreadStore(project: safe.fx.project).activeThreadID() == result.thread)
        let next = try await safe.run("write=a.txt")
        #expect(next.outcome == .skippedProjectBusy)
    }
}
