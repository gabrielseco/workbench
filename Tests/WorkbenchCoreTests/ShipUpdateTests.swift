import Foundation
import Testing

@testable import WorkbenchCore

private struct UpdateThread {
    var id: String
    var worktree: URL
    var bare: URL
}

private func acceptedUpdateThread(_ fx: RunnerFixture) async throws -> UpdateThread {
    let bare = try await originWithBranch(fx)
    let id = try await approvedUpdateThread(fx)
    _ = try await fx.runner(id).run(fx.options())
    let worktree = fx.project.worktreesDirectory.appendingPathComponent(id)
    try "one\nhello\n".write(to: worktree.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    try await fx.service.accept(id: id, message: "chore: update the pull request")
    return UpdateThread(id: id, worktree: worktree, bare: bare)
}

private func openPR(_ gh: FakeGH, branch: String = "feature/pr", head: String = String(repeating: "a", count: 40)) throws {
    try gh.put(
        "list",
        """
        [{"number":12,"url":"https://github.com/o/r/pull/12","headRefName":"\(branch)","baseRefName":"main","headRefOid":"\(head)"}]
        """)
}

private func remoteRef(_ bare: URL, _ ref: String, _ fx: RunnerFixture) async throws -> String {
    try await shipOut(["rev-parse", "-q", "--verify", ref], bare, fx)
}

private func runShip(_ arguments: [String], fx: RunnerFixture, gh: FakeGH) async throws -> (code: Int32?, text: String) {
    let environment = [
        "PATH": "\(gh.dir.path):/usr/bin:/bin", "HOME": NSHomeDirectory(), "USER": NSUserName(),
        "GH_FAKE_DIR": gh.dir.path,
    ]
    var spawn = SpawnRequest(
        executable: WorkbenchBinary.executable, arguments: ["ship"] + arguments, environment: environment,
        workingDirectory: fx.repo, timeout: 120)
    spawn.snapshotInterval = 3600
    let run = try ProcessRunner.start(spawn)
    var lines: [String] = []
    var exit: ProcessExit?
    for await event in run.events {
        if case .line(let line) = event { lines.append(line) }
        if case .exited(let e) = event { exit = e }
    }
    var code: Int32?
    if case .exited(let c)? = exit?.termination { code = c }
    return (code, (lines + [exit?.stderrTail ?? ""]).joined(separator: "\n"))
}

@Suite struct ShipUpdateTests {
    @Test func theWorkGoesToTheExistingBranchAndNoWorkbenchBranchReachesOrigin() async throws {
        let fx = try await RunnerFixture()
        let thread = try await acceptedUpdateThread(fx)
        let gh = try FakeGH(in: fx)
        let head = try await shipOut(["rev-parse", "HEAD"], thread.worktree, fx)
        try openPR(gh, head: head)

        let plan = try await fx.service.shipPreflight(id: thread.id, gh: gh.runner)
        #expect(plan.remoteBranch == "feature/pr" && plan.updatesExistingBranch)
        guard case .behind = plan.remote else {
            Issue.record("expected a fast-forward, got \(plan.remote)")
            return
        }

        let first = try await fx.service.shipPush(id: thread.id, gh: gh.runner, shown: plan)
        #expect(first.outcome == .pushed)
        #expect(try await remoteRef(thread.bare, "refs/heads/feature/pr", fx) == head)
        #expect(try await remoteRef(thread.bare, "refs/heads/workbench/\(thread.id)", fx).isEmpty)

        let second = try await fx.service.shipPush(id: thread.id, gh: gh.runner)
        #expect(second.outcome == .alreadyOnOrigin)
    }

    @Test func theExistingPullRequestIsRecordedAndNoneIsCreated() async throws {
        let fx = try await RunnerFixture()
        let thread = try await acceptedUpdateThread(fx)
        let gh = try FakeGH(in: fx)
        let head = try await shipOut(["rev-parse", "HEAD"], thread.worktree, fx)
        try openPR(gh, head: head)

        _ = try await fx.service.shipPush(id: thread.id, gh: gh.runner)
        let result = try await fx.service.shipOpenPR(id: thread.id, gh: gh.runner)
        #expect(result.outcome == .existing && result.number == 12)
        #expect(gh.count("pr create") == 0)
        let opened = try #require(try fx.events(thread.id).last { $0.kind == .prOpened })
        #expect(opened.data["branch"]?.stringValue == "feature/pr")
        #expect(opened.data["url"]?.stringValue == "https://github.com/o/r/pull/12")
    }

    @Test func aPullRequestStillShowingAnOlderHeadIsNotRecordedAndTheRetryWorks() async throws {
        let fx = try await RunnerFixture()
        let thread = try await acceptedUpdateThread(fx)
        let gh = try FakeGH(in: fx)
        let head = try await shipOut(["rev-parse", "HEAD"], thread.worktree, fx)
        let stale = String(repeating: "b", count: 40)
        try openPR(gh, head: stale)

        _ = try await fx.service.shipPush(id: thread.id, gh: gh.runner)
        do {
            _ = try await fx.service.shipOpenPR(id: thread.id, gh: gh.runner)
            Issue.record("expected a refusal")
        } catch let error as ShipError {
            #expect(error == .pullRequestBehind(pr: stale))
        }
        #expect(!(try fx.kinds(thread.id)).contains("pr.opened"))

        try openPR(gh, head: head)
        let result = try await fx.service.shipOpenPR(id: thread.id, gh: gh.runner)
        #expect(result.outcome == .existing)
        #expect(try fx.events(thread.id).last { $0.kind == .prOpened }?.data["head_sha"]?.stringValue == head)
        #expect(await fx.service.cleanShipped(id: thread.id, gh: gh.runner) == .removed(path: thread.worktree.path))
    }

    @Test func withoutAnOpenPullRequestNothingIsPushedCreatedOrRecorded() async throws {
        let fx = try await RunnerFixture()
        let thread = try await acceptedUpdateThread(fx)
        let gh = try FakeGH(in: fx)
        let before = try await remoteRef(thread.bare, "refs/heads/feature/pr", fx)

        do {
            _ = try await fx.service.shipPush(id: thread.id, gh: gh.runner)
            Issue.record("expected a refusal")
        } catch let error as ShipError {
            #expect(error == .noPullRequest("feature/pr"))
        }
        do {
            _ = try await fx.service.shipOpenPR(id: thread.id, gh: gh.runner)
            Issue.record("expected a refusal")
        } catch let error as ShipError {
            #expect(error == .noPullRequest("feature/pr"))
        }
        #expect(try await remoteRef(thread.bare, "refs/heads/feature/pr", fx) == before)
        #expect(gh.count("pr create") == 0)
        #expect(!(try fx.kinds(thread.id)).contains("pr.opened"))
    }

    @Test func theCommandRefusesWithExitSixAndLeavesTheBranchAloneWhenNoPullRequestIsOpen() async throws {
        let fx = try await RunnerFixture()
        let thread = try await acceptedUpdateThread(fx)
        let gh = try FakeGH(in: fx)
        let before = try await remoteRef(thread.bare, "refs/heads/feature/pr", fx)

        let shipped = try await runShip(["--yes"], fx: fx, gh: gh)
        #expect(shipped.code == 6, "\(shipped.text)")
        #expect(shipped.text.contains("no open pull request uses it"))
        #expect(try await remoteRef(thread.bare, "refs/heads/feature/pr", fx) == before)
    }

    @Test func aBranchThatMovedAfterTheThreadStartedIsNeverForced() async throws {
        let fx = try await RunnerFixture()
        let thread = try await acceptedUpdateThread(fx)
        let gh = try FakeGH(in: fx)

        let other = fx.repo.deletingLastPathComponent().appendingPathComponent("other-\(UUID().uuidString)")
        _ = try await fx.git.run(["clone", "-q", "-b", "feature/pr", thread.bare.path, other.path], in: fx.repo)
        try "later\n".write(to: other.appendingPathComponent("c.txt"), atomically: true, encoding: .utf8)
        _ = try await fx.git.run(["add", "-A"], in: other)
        _ = try await fx.git.run(["commit", "-q", "-m", "someone else"], in: other)
        _ = try await fx.git.run(["push", "-q", "origin", "feature/pr"], in: other)
        let theirs = try await shipOut(["rev-parse", "HEAD"], other, fx)

        do {
            _ = try await fx.service.shipPush(id: thread.id, gh: gh.runner)
            Issue.record("expected a refusal")
        } catch let error as ShipError {
            #expect(error == .branchMoved(branch: "feature/pr", sha: theirs))
        }
        #expect(try await remoteRef(thread.bare, "refs/heads/feature/pr", fx) == theirs)
    }

    @Test func aBranchDeletedFromOriginIsReportedNotRecreated() async throws {
        let fx = try await RunnerFixture()
        let thread = try await acceptedUpdateThread(fx)
        let gh = try FakeGH(in: fx)
        _ = try await fx.git.run(["branch", "-q", "-D", "feature/pr"], in: thread.bare)

        do {
            _ = try await fx.service.shipPush(id: thread.id, gh: gh.runner)
            Issue.record("expected a refusal")
        } catch let error as ShipError {
            #expect(error == .pushTargetMissing("feature/pr"))
        }
        #expect(try await remoteRef(thread.bare, "refs/heads/feature/pr", fx).isEmpty)
    }

    @Test func theWorktreeIsRemovedAfterShippingToTheExistingBranch() async throws {
        let fx = try await RunnerFixture()
        let thread = try await acceptedUpdateThread(fx)
        let gh = try FakeGH(in: fx)
        let head = try await shipOut(["rev-parse", "HEAD"], thread.worktree, fx)
        try openPR(gh, head: head)
        _ = try await fx.service.shipPush(id: thread.id, gh: gh.runner)
        _ = try await fx.service.shipOpenPR(id: thread.id, gh: gh.runner)

        let result = await fx.service.cleanShipped(id: thread.id, gh: gh.runner)
        #expect(result == .removed(path: thread.worktree.path))
    }

    @Test func theCommandNamesTheBranchSkipsTheDescriptionAndPrintsTheExistingPullRequest() async throws {
        let fx = try await RunnerFixture()
        let thread = try await acceptedUpdateThread(fx)
        let gh = try FakeGH(in: fx)
        let head = try await shipOut(["rev-parse", "HEAD"], thread.worktree, fx)
        try openPR(gh, head: head)

        let shipped = try await runShip(["--yes"], fx: fx, gh: gh)
        #expect(shipped.code == 0, "\(shipped.text)")
        #expect(shipped.text.contains("updates: feature/pr on origin"))
        #expect(shipped.text.contains("its title and description stay as they are"))
        #expect(!shipped.text.contains("describing the change"))
        #expect(shipped.text.contains("pushed feature/pr"))
        #expect(shipped.text.contains("https://github.com/o/r/pull/12"))
        #expect(gh.count("pr create") == 0)
        #expect(try await remoteRef(thread.bare, "refs/heads/feature/pr", fx) == head)
    }
}
