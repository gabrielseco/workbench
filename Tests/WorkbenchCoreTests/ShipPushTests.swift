import Foundation
import Testing

@testable import WorkbenchCore

private func hook(_ name: String, _ body: String, in bare: URL) throws {
    let url = bare.appendingPathComponent("hooks/\(name)")
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
    chmod(url.path, 0o755)
}

private func remoteTip(_ bare: URL, _ id: String, _ fx: RunnerFixture) async throws -> String {
    try await shipOut(["rev-parse", "-q", "--verify", "refs/heads/workbench/\(id)"], bare, fx)
}

private func pushRefusal(_ body: () async throws -> ShipPushResult) async -> ShipError? {
    do {
        _ = try await body()
        return nil
    } catch {
        return error as? ShipError
    }
}

@Suite(.processGate) struct ShipPushTests {
    @Test func aPushPutsTheBranchOnOriginSetsUpstreamAndASecondRunPushesNothing() async throws {
        let fx = try await RunnerFixture()
        let (id, worktree) = try await acceptedThread(fx)
        let bare = try await addOrigin(fx)
        let gh = try fakeGH(status: 0, in: fx)
        let head = try await shipOut(["rev-parse", "HEAD"], worktree, fx)

        let first = try await fx.service.shipPush(id: id, gh: gh)
        #expect(first.outcome == .pushed)
        #expect(try await remoteTip(bare, id, fx) == head)
        let branch = "workbench/\(id)"
        #expect(try await shipOut(["config", "branch.\(branch).remote"], fx.repo, fx) == "origin")
        #expect(try await shipOut(["config", "branch.\(branch).merge"], fx.repo, fx) == "refs/heads/\(branch)")

        let second = try await fx.service.shipPush(id: id, gh: gh)
        #expect(second.outcome == .alreadyOnOrigin)
        #expect(try fx.events(id).last?.data["decision"]?.stringValue == "accepted", "no event was written")
    }

    @Test func commitsAfterAcceptAreRecordedOncePerHeadOldestFirstAndAtMostTen() async throws {
        let fx = try await RunnerFixture()
        let (id, worktree) = try await acceptedThread(fx)
        _ = try await addOrigin(fx)
        let gh = try fakeGH(status: 0, in: fx)
        for n in 1...12 {
            try "\(n)\n".write(to: worktree.appendingPathComponent("f\(n).txt"), atomically: true, encoding: .utf8)
            _ = try await fx.git.run(["add", "-A"], in: worktree)
            _ = try await fx.git.run(["commit", "-q", "-m", "fix \(n)"], in: worktree)
        }

        let first = try await fx.service.shipPush(id: id, gh: gh)
        #expect(first.outcome == .pushed)
        #expect(first.ahead?.count == 12)
        #expect(first.ahead?.commits.map(\.subject) == (1...10).map { "fix \($0)" })
        // Run again (as after a failed PR step): origin has the head, and the event is not written twice.
        let second = try await fx.service.shipPush(id: id, gh: gh)
        #expect(second.outcome == .alreadyOnOrigin)
        let ahead = try fx.events(id).filter { $0.kind == .branchAhead }
        #expect(ahead.count == 1)
        guard case .array(let commits)? = ahead.first?.data["commits"] else {
            Issue.record("no commits array")
            return
        }
        #expect(commits.count == 10 && commits.first?["subject"]?.stringValue == "fix 1")

        let line = LogFormatter.describe(try #require(ahead.first))
        #expect(!line.contains("\n"))
        #expect(line.contains("branch ahead of accept: 10+ commit(s)"), "\(line)")
    }

    @Test func branchAheadIsDocumentedInTheEventLogSpec() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/spec/event-log.md")
        let text = try String(contentsOf: url, encoding: .utf8)
        let row = try #require(text.split(separator: "\n").first { $0.hasPrefix("| `branch.ahead` | `accepted`") })
        for field in ["`head`", "`commits`", "`sha`", "`subject`", "100 characters", "before it pushes"] {
            #expect(row.contains(field), "\(field)")
        }
    }

    @Test func anAncestorOnOriginIsFastForwarded() async throws {
        let fx = try await RunnerFixture()
        let (id, worktree) = try await acceptedThread(fx)
        let bare = try await addOrigin(fx)
        let mainSHA = try await shipOut(["rev-parse", "main"], fx.repo, fx)
        _ = try await fx.git.run(["push", "-q", bare.path, "\(mainSHA):refs/heads/workbench/\(id)"], in: fx.repo)

        let result = try await fx.service.shipPush(id: id, gh: fakeGH(status: 0, in: fx))
        #expect(result.outcome == .pushed)
        #expect(try await remoteTip(bare, id, fx) == (try await shipOut(["rev-parse", "HEAD"], worktree, fx)))
    }

    @Test func aPreflightRefusalPushesNothing() async throws {
        let fx = try await RunnerFixture()
        let (id, worktree) = try await acceptedThread(fx)
        let bare = try await addOrigin(fx)
        let loggedOut = await pushRefusal { try await fx.service.shipPush(id: id, gh: fakeGH(status: 1, in: fx)) }
        #expect(loggedOut == .ghNotAuthenticated)
        #expect(try await originBranches(bare, fx) == ["refs/heads/main"])

        try "x".write(to: worktree.appendingPathComponent("loose.txt"), atomically: true, encoding: .utf8)
        do {
            _ = try await fx.service.shipPush(id: id, gh: fakeGH(status: 0, in: fx))
            Issue.record("expected a refusal")
        } catch let error as ShipError {
            guard case .uncommitted = error else {
                Issue.record("got \(error)")
                return
            }
        }
        #expect(try await originBranches(bare, fx) == ["refs/heads/main"])
    }

    @Test func aPlanThatChangedAfterItWasShownPushesNothing() async throws {
        let fx = try await RunnerFixture()
        let (id, _) = try await acceptedThread(fx)
        let bare = try await addOrigin(fx)
        let gh = try fakeGH(status: 0, in: fx)
        let shown = try await fx.service.shipPreflight(id: id, gh: gh)

        // The person answered yes to origin A; origin is now B.
        let second = fx.repo.deletingLastPathComponent().appendingPathComponent("other-\(UUID().uuidString).git")
        _ = try await fx.git.run(["init", "-q", "--bare", second.path], in: fx.repo)
        _ = try await fx.git.run(["push", "-q", second.path, "main"], in: fx.repo)
        _ = try await fx.git.run(["remote", "set-url", "origin", second.path], in: fx.repo)
        do {
            _ = try await fx.service.shipPush(id: id, gh: gh, shown: shown)
            Issue.record("expected a refusal")
        } catch let error as ShipError {
            #expect(error == .changedSinceShown)
        }
        #expect(try await originBranches(second, fx) == ["refs/heads/main"])
        #expect(try await originBranches(bare, fx) == ["refs/heads/main"])

        // After the push the wording must not claim that nothing was published.
        #expect(ShipError.changedAfterPush.description.contains("was pushed"))
        #expect(!ShipError.changedAfterPush.description.contains("nothing was published"))
    }

    @Test func thereIsNoForceInTheArguments() {
        let args = ThreadService.pushArguments(branch: "workbench/g-1")
        #expect(args == ["push", "--set-upstream", "origin", "refs/heads/workbench/g-1:refs/heads/workbench/g-1"])
        #expect(!args.contains { $0 == "-f" || $0.hasPrefix("--force") || $0.hasPrefix("+") || $0.contains(":+") })
    }

    @Test func aRejectedPushIsReportedLeavesTheThreadAsItWasAndCanBeRepeated() async throws {
        let fx = try await RunnerFixture()
        let (id, worktree) = try await acceptedThread(fx)
        let bare = try await addOrigin(fx)
        let gh = try fakeGH(status: 0, in: fx)
        try hook("pre-receive", "echo 'rejected by policy: no friday pushes' >&2\nexit 1", in: bare)
        let eventsBefore = try fx.events(id).count

        do {
            _ = try await fx.service.shipPush(id: id, gh: gh)
            Issue.record("expected a rejection")
        } catch let error as ShipError {
            guard case .pushRejected(let why) = error else {
                Issue.record("got \(error)")
                return
            }
            #expect(why.contains("rejected by policy"), "\(why)")
        }
        #expect(try await originBranches(bare, fx) == ["refs/heads/main"])
        #expect(try fx.events(id).count == eventsBefore)
        #expect(try await shipOut(["status", "--porcelain"], worktree, fx).isEmpty)

        try FileManager.default.removeItem(at: bare.appendingPathComponent("hooks/pre-receive"))
        #expect(try await fx.service.shipPush(id: id, gh: gh).outcome == .pushed)
    }

    @Test func credentialsInTheRemotesMessageAreRemoved() async throws {
        let fx = try await RunnerFixture()
        let (id, _) = try await acceptedThread(fx)
        let bare = try await addOrigin(fx)
        try hook("pre-receive", "echo 'see https://user:sekret@git.example/x.git' >&2\nexit 1", in: bare)

        do {
            _ = try await fx.service.shipPush(id: id, gh: fakeGH(status: 0, in: fx))
            Issue.record("expected a rejection")
        } catch let error as ShipError {
            #expect(!error.description.contains("sekret"), "\(error)")
            #expect(error.description.contains("https://git.example/x.git"))
        }
    }

    @Test func aCredentialUrlCrossingTheCutIsStillRedacted() async throws {
        let fx = try await RunnerFixture()
        let (id, _) = try await acceptedThread(fx)
        let bare = try await addOrigin(fx)
        // The URL starts so that the 2000-character cut would have fallen inside `user:token@`.
        let filler = String(repeating: "x", count: 1_990)
        try hook("pre-receive", "echo \"\(filler) https://user:sekret@git.example/p\" >&2\nexit 1", in: bare)

        let error = await pushRefusal { try await fx.service.shipPush(id: id, gh: fakeGH(status: 0, in: fx)) }
        guard case .pushRejected(let why)? = error else {
            Issue.record("got \(String(describing: error))")
            return
        }
        #expect(!why.contains("sekret") && !why.contains("user:"), "\(why)")
        #expect(why.count <= 2_000)
    }

    @Test func aHungPushEndsInATimeoutLeavesNoProcessAndCanBeRepeated() async throws {
        let fx = try await RunnerFixture()
        let (id, _) = try await acceptedThread(fx)
        let bare = try await addOrigin(fx)
        let gh = try fakeGH(status: 0, in: fx)
        let pidFile = bare.appendingPathExtension("pid")
        try hook("pre-receive", "echo $$ > '\(pidFile.path)'\nexec sleep 600", in: bare)

        // The push timeout starts at the spawn, before the hook has written its pid, so a short one flakes on a loaded
        // runner. The test ends the push as the timeout would (`CommandExpiry`) once the hook is running.
        let expiry = CommandExpiry()
        let service = ThreadService(
            project: fx.project,
            git: GitRunner(
                executable: fx.git.executable, environment: fx.git.environment, timeout: fx.git.timeout, expiry: expiry))
        let started = Date()
        let push = Task { try await service.shipPush(id: id, gh: gh, timeout: 600) }
        #expect(await pollUntil { FileManager.default.fileExists(atPath: pidFile.path) }, "the hook ran")
        expiry.expire()
        do {
            _ = try await push.value
            Issue.record("expected a timeout")
        } catch let error as ShipError {
            guard case .gitFailed(let why) = error else {
                Issue.record("got \(error)")
                return
            }
            #expect(why.contains("did not finish"), "\(why)")
        }
        // The timer was set for 600 s: ending inside the test's patience is `expire()` having reached the push.
        #expect(Date().timeIntervalSince(started) < Patience.limit)
        let written = (try? String(contentsOf: pidFile, encoding: .utf8)) ?? ""
        let pid = Int32(written.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(pid != nil, "the hook ran")
        if let pid {
            try await Task.sleep(nanoseconds: 300_000_000)
            #expect(kill(pid, 0) != 0, "the hook is gone")
        }
        #expect(try await originBranches(bare, fx) == ["refs/heads/main"])

        try FileManager.default.removeItem(at: bare.appendingPathComponent("hooks/pre-receive"))
        #expect(try await fx.service.shipPush(id: id, gh: gh).outcome == .pushed)
    }
}
