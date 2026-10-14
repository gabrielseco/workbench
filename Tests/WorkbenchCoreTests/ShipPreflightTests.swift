import Foundation
import Testing

@testable import WorkbenchCore

/// An accepted thread: one turn that changed `a.txt`, then `accept`.
private func acceptedThread(_ fx: RunnerFixture) async throws -> (id: String, worktree: URL) {
    let id = try await fx.approvedThread()
    _ = try await fx.runner(id).run(fx.options())
    let worktree = fx.project.worktreesDirectory.appendingPathComponent(id)
    try "one\nhello\n".write(to: worktree.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    try await fx.service.accept(id: id, message: "chore: work")
    return (id, worktree)
}

/// A `gh` stand-in: a script that exits with `status`, as a runner.
private func fakeGH(status: Int, in fx: RunnerFixture) throws -> GitRunner {
    let script = fx.repo.deletingLastPathComponent().appendingPathComponent("gh-\(UUID().uuidString).sh")
    try "#!/bin/sh\necho \"token ghp_secret\" >&2\nexit \(status)\n".write(to: script, atomically: true, encoding: .utf8)
    chmod(script.path, 0o755)
    return GitRunner(executable: script, environment: ["PATH": "/usr/bin:/bin"], timeout: 10)
}

private func out(_ args: [String], _ dir: URL, _ fx: RunnerFixture) async throws -> String {
    try await fx.git.run(args, in: dir).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// A bare repository added as `origin`.
private func addOrigin(_ fx: RunnerFixture) async throws -> URL {
    let bare = fx.repo.deletingLastPathComponent().appendingPathComponent("origin-\(UUID().uuidString).git")
    _ = try await fx.git.run(["init", "-q", "--bare", bare.path], in: fx.repo)
    _ = try await fx.git.run(["remote", "add", "origin", bare.path], in: fx.repo)
    return bare
}

private func refusal(_ body: () async throws -> ShipPlan) async -> ShipError? {
    do {
        _ = try await body()
        return nil
    } catch let error as ShipError {
        return error
    } catch {
        Issue.record("unexpected error \(error)")
        return nil
    }
}

@Suite struct ShipPreflightTests {
    @Test func anAcceptedCleanThreadWithOriginAndGHIsAllowed() async throws {
        let fx = try await RunnerFixture()
        let (id, worktree) = try await acceptedThread(fx)
        _ = try await addOrigin(fx)

        let plan = try await fx.service.shipPreflight(id: id, gh: fakeGH(status: 0, in: fx))
        #expect(plan.branch == "workbench/\(id)" && plan.base == "main")
        #expect(plan.head == (try await out(["rev-parse", "HEAD"], worktree, fx)))
        #expect(plan.remote == .absent)
        // Reading only: the log has no new event and the repository has no new ref.
        #expect(try fx.events(id).last?.data["decision"]?.stringValue == "accepted")
    }

    @Test func aThreadThatIsNotAcceptedIsRefusedWithTheReason() async throws {
        let fx = try await RunnerFixture()
        _ = try await addOrigin(fx)
        let gh = try fakeGH(status: 0, in: fx)

        let active = try await fx.approvedThread()
        _ = try await fx.runner(active).run(fx.options())
        let first = await refusal { try await fx.service.shipPreflight(id: active, gh: gh) }
        #expect(first == .notAccepted("it is still active"))

        let missing = await refusal { try await fx.service.shipPreflight(id: "g-nope", gh: gh) }
        #expect(missing == .notAccepted("no such thread"))

        let discarded = try await fx.service.discardPlan(id: active)
        try await fx.service.discard(id: active, shown: discarded)
        let ended = await refusal { try await fx.service.shipPreflight(id: active, gh: gh) }
        #expect(ended == .notAccepted("discarded"))
    }

    @Test func aShippedThreadIsRefusedWithItsURL() async throws {
        let fx = try await RunnerFixture()
        let (id, _) = try await acceptedThread(fx)
        _ = try await addOrigin(fx)
        let log = try EventLogWriter.open(at: fx.project.eventsURL(id))
        _ = try await log.append(
            .prOpened, data: ["url": "https://github.com/o/r/pull/7", "number": 7, "branch": "b", "base": "main", "head_sha": "x"])
        await log.close()

        let error = await refusal { try await fx.service.shipPreflight(id: id, gh: fakeGH(status: 0, in: fx)) }
        #expect(error == .alreadyShipped(url: "https://github.com/o/r/pull/7"))
    }

    @Test func uncommittedWorkAndAWrongBranchAreRefused() async throws {
        let fx = try await RunnerFixture()
        let (id, worktree) = try await acceptedThread(fx)
        _ = try await addOrigin(fx)
        let gh = try fakeGH(status: 0, in: fx)

        for (name, text) in [("loose.txt", "x"), ("a.txt", "changed")] {
            try text.write(to: worktree.appendingPathComponent(name), atomically: true, encoding: .utf8)
            let error = await refusal { try await fx.service.shipPreflight(id: id, gh: gh) }
            guard case .uncommitted(let lines)? = error else {
                Issue.record("\(name): expected uncommitted, got \(String(describing: error))")
                continue
            }
            #expect(lines.contains { $0.contains(name) })
            _ = try await fx.git.run(["checkout", "-q", "--", "a.txt"], in: worktree)
            try? FileManager.default.removeItem(at: worktree.appendingPathComponent("loose.txt"))
        }

        _ = try await fx.git.run(["checkout", "-q", "--detach"], in: worktree)
        let detached = await refusal { try await fx.service.shipPreflight(id: id, gh: gh) }
        #expect(detached == .wrongBranch(expected: "workbench/\(id)", found: ""))
    }

    @Test func ignoredFilesDoNotCountAsUncommitted() async throws {
        let fx = try await RunnerFixture()
        let (id, worktree) = try await acceptedThread(fx)
        _ = try await addOrigin(fx)
        try "*.log\n".write(
            to: worktree.appendingPathComponent(".git").deletingLastPathComponent().appendingPathComponent(".gitignore"),
            atomically: true, encoding: .utf8)
        _ = try await fx.git.run(["add", ".gitignore"], in: worktree)
        _ = try await fx.git.run(["commit", "-q", "-m", "ignore logs"], in: worktree)
        try "noise".write(to: worktree.appendingPathComponent("x.log"), atomically: true, encoding: .utf8)

        let plan = try await fx.service.shipPreflight(id: id, gh: fakeGH(status: 0, in: fx))
        #expect(plan.branch == "workbench/\(id)")
    }

    @Test func aMissingWorktreeIsRefused() async throws {
        let fx = try await RunnerFixture()
        let (id, worktree) = try await acceptedThread(fx)
        _ = try await addOrigin(fx)
        try FileManager.default.removeItem(at: worktree)
        let error = await refusal { try await fx.service.shipPreflight(id: id, gh: fakeGH(status: 0, in: fx)) }
        guard case .worktreeMissing? = error else {
            Issue.record("got \(String(describing: error))")
            return
        }
    }

    @Test func noOriginIsRefused() async throws {
        let fx = try await RunnerFixture()
        let (id, _) = try await acceptedThread(fx)
        let error = await refusal { try await fx.service.shipPreflight(id: id, gh: fakeGH(status: 0, in: fx)) }
        #expect(error == .noOrigin)
    }

    @Test func credentialsInTheOriginNeverAppearInAnythingShown() async throws {
        #expect(ThreadService.withoutCredentials("https://user:tok@github.com/o/r.git") == "https://github.com/o/r.git")
        #expect(ThreadService.withoutCredentials("fatal: unable to access 'https://tok@127.0.0.1:1/x.git/'")
            == "fatal: unable to access 'https://127.0.0.1:1/x.git/'")
        #expect(ThreadService.withoutCredentials("git@github.com:o/r.git") == "git@github.com:o/r.git")

        let fx = try await RunnerFixture()
        let (id, _) = try await acceptedThread(fx)
        _ = try await fx.git.run(["remote", "add", "origin", "http://sekret@127.0.0.1:1/x.git"], in: fx.repo)
        let error = await refusal { try await fx.service.shipPreflight(id: id, gh: fakeGH(status: 0, in: fx)) }
        guard case .remoteUnreachable(let why)? = error else {
            Issue.record("got \(String(describing: error))")
            return
        }
        #expect(!why.contains("sekret"), "\(why)")
    }

    @Test func ghMissingOrLoggedOutIsRefusedWithoutEchoingItsOutput() async throws {
        let fx = try await RunnerFixture()
        let (id, _) = try await acceptedThread(fx)
        _ = try await addOrigin(fx)

        let missing = await refusal { try await fx.service.shipPreflight(id: id, gh: nil) }
        #expect(missing == .ghMissing)

        let out = await refusal { try await fx.service.shipPreflight(id: id, gh: fakeGH(status: 1, in: fx)) }
        #expect(out == .ghNotAuthenticated)
        #expect(!ShipError.ghNotAuthenticated.description.contains("ghp_"))
    }

    @Test func theRemoteBranchMustBeOursOrAnAncestor() async throws {
        let fx = try await RunnerFixture()
        let (id, worktree) = try await acceptedThread(fx)
        let bare = try await addOrigin(fx)
        let gh = try fakeGH(status: 0, in: fx)
        let branch = "workbench/\(id)"
        let head = try await out(["rev-parse", "HEAD"], worktree, fx)
        let mainSHA = try await out(["rev-parse", "main"], fx.repo, fx)

        // An ancestor (the base) is a plain fast-forward.
        _ = try await fx.git.run(["push", "-q", bare.path, "\(mainSHA):refs/heads/\(branch)"], in: fx.repo)
        let before = try await out(["for-each-ref", "refs/remotes"], fx.repo, fx)
        let behind = try await fx.service.shipPreflight(id: id, gh: gh)
        #expect(behind.remote == .behind(sha: mainSHA))

        // Exactly ours: nothing to push.
        _ = try await fx.git.run(["push", "-q", "-f", bare.path, "\(head):refs/heads/\(branch)"], in: fx.repo)
        #expect(try await fx.service.shipPreflight(id: id, gh: gh).remote == .upToDate)

        // Diverged: a commit on top of the base that is not ours.
        let other = fx.repo.deletingLastPathComponent().appendingPathComponent("clone-\(UUID().uuidString)")
        _ = try await fx.git.run(["clone", "-q", bare.path, other.path], in: fx.repo)
        _ = try await fx.git.run(["checkout", "-q", "-b", "x", mainSHA], in: other)
        try "other\n".write(to: other.appendingPathComponent("o.txt"), atomically: true, encoding: .utf8)
        _ = try await fx.git.run(["add", "-A"], in: other)
        _ = try await fx.git.run(["commit", "-q", "-m", "other"], in: other)
        let theirs = try await out(["rev-parse", "HEAD"], other, fx)
        _ = try await fx.git.run(["push", "-q", "-f", bare.path, "HEAD:refs/heads/\(branch)"], in: other)
        let diverged = await refusal { try await fx.service.shipPreflight(id: id, gh: gh) }
        // The commit is not in this repository, so it is refused without fetching it.
        #expect(diverged == .remoteDiverged(sha: theirs))
        #expect(try await fx.git.run(["cat-file", "-e", theirs], in: fx.repo).status != 0, "nothing was fetched")
        #expect(try await out(["for-each-ref", "refs/remotes"], fx.repo, fx) == before)
    }

    @Test func aBaseThatLooksLikeAnOptionNeverReachesGit() async throws {
        let fx = try await RunnerFixture()
        let (id, _) = try await acceptedThread(fx)
        _ = try await addOrigin(fx)
        let url = fx.project.goalURL(id)
        let text = try String(contentsOf: url, encoding: .utf8)
        try text.replacingOccurrences(of: "base: main", with: "base: --upload-pack=x")
            .write(to: url, atomically: true, encoding: .utf8)

        let error = await refusal { try await fx.service.shipPreflight(id: id, gh: fakeGH(status: 0, in: fx)) }
        #expect(error != nil)
        let bad = await refusal { try await fx.service.shipPreflight(id: "--x", gh: nil) }
        #expect(bad == .invalidName("--x"))
    }

    @Test func aHungOriginEndsInATimeoutAndLeavesNoProcess() async throws {
        let fx = try await RunnerFixture()
        let (id, _) = try await acceptedThread(fx)
        let bare = try await addOrigin(fx)
        let pidFile = bare.appendingPathExtension("pid")
        let hang = bare.appendingPathExtension("sh")
        try "#!/bin/sh\necho $$ > '\(pidFile.path)'\nexec sleep 60\n".write(to: hang, atomically: true, encoding: .utf8)
        chmod(hang.path, 0o755)
        _ = try await fx.git.run(["config", "remote.origin.uploadpack", hang.path], in: fx.repo)

        let slow = ThreadService(
            project: fx.project, git: GitRunner(executable: fx.git.executable, environment: fx.git.environment, timeout: 3))
        let started = Date()
        let error = await refusal { try await slow.shipPreflight(id: id, gh: fakeGH(status: 0, in: fx)) }
        guard case .gitFailed(let why)? = error else {
            Issue.record("got \(String(describing: error))")
            return
        }
        #expect(why.contains("ls-remote"), "\(why)")
        #expect(Date().timeIntervalSince(started) < 30)
        let written = (try? String(contentsOf: pidFile, encoding: .utf8)) ?? ""
        if let pid = Int32(written.trimmingCharacters(in: .whitespacesAndNewlines)) {
            try await Task.sleep(nanoseconds: 300_000_000)
            #expect(kill(pid, 0) != 0, "the helper is gone")
        }
    }
}
