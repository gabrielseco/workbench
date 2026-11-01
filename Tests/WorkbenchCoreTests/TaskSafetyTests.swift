import Foundation
import Testing

@testable import WorkbenchCore

/// A task with four units in a project with a real repository, the fake claude, a fake gh and an origin.
private struct Safe {
    let fx: RunnerFixture
    let task: TaskFixture
    let gh: FakeGH
    let marker: URL
    let origin: URL

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
        origin = try await addOrigin(fx)
    }

    /// Origin gets a commit the local main and its remote-tracking branch do not have: both are put back one commit behind.
    func putOriginAhead() async throws -> (old: String, new: String) {
        func git(_ args: [String]) async throws -> String {
            try await fx.git.run(args, in: fx.repo).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let old = try await git(["rev-parse", "HEAD"])
        try "ahead\n".write(to: fx.repo.appendingPathComponent("ahead.txt"), atomically: true, encoding: .utf8)
        _ = try await git(["add", "ahead.txt"])
        _ = try await git(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "ahead"])
        let new = try await git(["rev-parse", "HEAD"])
        _ = try await git(["push", "-q", "origin", "main"])
        _ = try await git(["reset", "-q", "--hard", old])
        _ = try await git(["update-ref", "refs/remotes/origin/main", old])
        return (old, new)
    }

    /// The goal file of the thread a run started.
    func goal(of result: TaskRunResult) throws -> Goal {
        let id = try #require(result.thread)
        return try GoalFile.parse(String(contentsOf: fx.project.goalURL(id), encoding: .utf8)).goal
    }

    /// The commit a thread was cut from, as its log says.
    func baseCommit(of thread: String) throws -> String? {
        try fx.events(thread).first { $0.kind == .worktreeCreated }?.data["base_commit"]?.stringValue
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

    /// What `gh pr list --state open` says when these runs' branches are open.
    func openList(_ results: [TaskRunResult], extra: Int = 0) throws {
        let branches = results.compactMap(\.thread).map { "workbench/\($0)" } + (0..<extra).map { "other/branch-\($0)" }
        let items = branches.map { "{\"headRefName\":\"\($0)\"}" }.joined(separator: ",")
        try gh.put("list_open", "[\(items)]")
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
        try safe.openList([first, second])
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
        try safe.gh.put("list_open", #"[{"headRefName":"workbench/g-1-bump-ROU"}]"#)
        let result = try await safe.run(try safe.shippable())
        #expect(result.outcome == .skippedTooManyOpen)
        #expect(result.reason?.contains("branch workbench/g-1-bump-ROU") == true)
        #expect(try safe.task.log.history().runs.first?.outcome == .interrupted)
        // GitHub says that branch has no pull request after all: the run goes ahead.
        try safe.gh.put("list_open", "[]")
        #expect(try await safe.run(try safe.shippable()).outcome == .prOpened)
    }

    @Test func aDryRunIsNotSkippedForAnActiveThread() async throws {
        let safe = try await Safe(front: "fix: report\nbatch: 1\npending: pending.sh")
        let active = try await safe.fx.approvedThread()
        let result = try await safe.run()
        #expect(result.outcome == .reported && result.units == ["ROU"])
        // It took nobody's place: the other thread is still the active one.
        #expect(ThreadStore(project: safe.fx.project).activeThreadID() == active)
    }

    @Test func aTaskThatStartsAThreadIsStillSkippedForAnActiveOne() async throws {
        let safe = try await Safe()
        let active = try await safe.fx.approvedThread()
        let result = try await safe.run()
        #expect(result.outcome == .skippedProjectBusy && result.reason?.contains(active) == true)
    }

    @Test func theTimeoutReachesTheGoalAndTheDefaultStandsWithout() async throws {
        let fails = #"check_command = "false""#
        let timed = try await Safe(front: "fix: pr\nbatch: 1\ntimeout: 45\npending: pending.sh", extraConfig: fails)
        let first = try await timed.run("write=a.txt")
        #expect(try timed.goal(of: first).turnTimeoutMin == 45)
        let plain = try await Safe(extraConfig: fails)
        let second = try await plain.run("write=a.txt")
        #expect(try plain.goal(of: second).turnTimeoutMin == 30)
    }

    @Test func aBaseOnOriginIsFetchedFirstSoTheThreadStartsFromTheFreshBranch() async throws {
        let failing = #"check_command = "false""#
        let safe = try await Safe(front: "fix: pr\nbatch: 1\nbase: origin/main\npending: pending.sh", extraConfig: failing)
        let heads = try await safe.putOriginAhead()
        let result = try await safe.run("write=a.txt")
        #expect(try safe.baseCommit(of: try #require(result.thread)) == heads.new)
        // Without the key the thread starts from the local main, which is behind.
        let stale = try await Safe(extraConfig: failing)
        let behind = try await stale.putOriginAhead()
        let other = try await stale.run("write=a.txt")
        #expect(try stale.baseCommit(of: try #require(other.thread)) == behind.old)
    }

    @Test func aBaseThatCannotBeFetchedStopsTheRunInsteadOfUsingAStaleOne() async throws {
        let safe = try await Safe(front: "fix: pr\nbatch: 1\nbase: origin/main\npending: pending.sh")
        _ = try await safe.fx.git.run(["remote", "set-url", "origin", "/nonexistent/origin.git"], in: safe.fx.repo)
        let result = try await safe.run("write=a.txt")
        #expect(result.outcome == .failed && result.thread == nil)
        #expect(result.reason?.contains("could not fetch origin/main, so nothing was started") == true)
        #expect(safe.threads().isEmpty)
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

    @Test func theLimitHoldsHoweverLongTheHistoryIs() async throws {
        // 40 earlier pull requests, 35 of them still open, and a limit above any fixed window of recent threads.
        let safe = try await Safe(front: "fix: pr\nbatch: 1\nmax_open: 31\npending: pending.sh")
        let writer = try await safe.task.log.openWriter()
        var open: [String] = []
        for index in 0..<40 {
            let thread = "g-1-bump-\(index)"
            try await writer.append(.taskRunStarted, data: ["trigger": "tick"])
            try await writer.append(.taskRunThread, data: ["thread": .string(thread), "units": ["ROU"]])
            try await writer.append(
                .taskRunEnded,
                data: [
                    "outcome": "pr-opened", "thread": .string(thread), "units": ["ROU"],
                    "pr": .string("https://github.com/o/r/pull/\(index)"),
                ])
            if index < 35 { open.append("{\"headRefName\":\"workbench/\(thread)\"}") }
        }
        await writer.close()
        try safe.gh.put("list_open", "[\(open.joined(separator: ","))]")
        let result = try await safe.run(try safe.shippable())
        #expect(result.outcome == .skippedTooManyOpen)
        #expect(result.reason?.contains("35 of the task's pull requests are still open (max_open 31)") == true)
    }

    @Test func anOpenListTooLongToBeCompleteIsNotTrusted() async throws {
        let safe = try await Safe()
        let first = try await safe.run(try safe.shippable())
        #expect(first.outcome == .prOpened)
        // As many open pull requests as the question allows: the answer may be cut, so the count cannot be known.
        try safe.openList([], extra: TaskPullRequests.openListLimit)
        let result = try await safe.run(try safe.shippable())
        #expect(result.outcome == .skippedTooManyOpen)
        #expect(result.reason?.contains("could not be read in full") == true)
    }

    @Test func aMergedOrClosedPullRequestNoLongerCounts() async throws {
        for state in ["MERGED", "CLOSED"] {
            let safe = try await Safe()
            let work = try safe.shippable()
            _ = try await safe.run(work)
            try safe.gh.put("list", #"[{"state":"OPEN"}]"#)
            _ = try await safe.run(work)
            try safe.gh.put("list", "[{\"state\":\"\(state)\"}]")
            try safe.openList([])
            let next = try await safe.run(work)
            #expect(next.outcome != .skippedTooManyOpen, "\(state): \(next.reason ?? "")")
        }
    }

    @Test func theLimitIsTheTasksOwnToSet() async throws {
        let safe = try await Safe(front: "fix: pr\nbatch: 1\nmax_open: 3\npending: pending.sh")
        let work = try safe.shippable()
        let first = try await safe.run(work)
        try safe.gh.put("list", #"[{"state":"OPEN"}]"#)
        var results = [first]
        for _ in 0..<3 {
            try safe.openList(results)
            results.append(try await safe.run(work))
        }
        #expect(results.map(\.outcome) == [.prOpened, .prOpened, .prOpened, .skippedTooManyOpen])
    }

    @Test func whenGitHubCannotBeAskedTheRunIsSkippedNotGuessed() async throws {
        let safe = try await Safe()
        let work = try safe.shippable()
        let first = try await safe.run(work)
        try safe.gh.put("list", #"[{"state":"OPEN"}]"#)
        let second = try await safe.run(work)
        try safe.openList([first, second])
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
