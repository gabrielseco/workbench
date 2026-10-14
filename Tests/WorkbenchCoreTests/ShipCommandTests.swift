import Foundation
import Testing

@testable import WorkbenchCore

private struct Shipped {
    var lines: [String]
    var exit: ProcessExit?
    var code: Int32? {
        if case .exited(let code)? = exit?.termination { return code }
        return nil
    }
    /// stdout lines, then what went to stderr.
    var text: String { (lines + [exit?.stderrTail ?? ""]).joined(separator: "\n") }
}

private func ship(_ arguments: [String], fx: RunnerFixture, gh: FakeGH?, withGH: Bool = true) async throws -> Shipped {
    let path = (withGH && gh != nil ? "\(gh!.dir.path):" : "") + "/usr/bin:/bin"
    var environment = ["PATH": path, "HOME": NSHomeDirectory(), "USER": NSUserName()]
    if let gh { environment["GH_FAKE_DIR"] = gh.dir.path }
    var spawn = SpawnRequest(
        executable: WorkbenchBinary.executable, arguments: ["ship"] + arguments, environment: environment,
        workingDirectory: fx.repo, timeout: 120)
    spawn.snapshotInterval = 3600
    let run = try ProcessRunner.start(spawn)
    var result = Shipped(lines: [], exit: nil)
    for await event in run.events {
        if case .line(let line) = event { result.lines.append(line) }
        if case .exited(let e) = event { result.exit = e }
    }
    return result
}

private func branches(_ bare: URL, _ fx: RunnerFixture) async throws -> String {
    try await shipOut(["for-each-ref", "refs/heads"], bare, fx)
}

@Suite struct ShipCommandTests {
    @Test func shipsTheAcceptedThreadPrintsTheURLLastAndASecondRunSaysAlreadyShipped() async throws {
        let fx = try await RunnerFixture()
        let gh = try FakeGH(in: fx)
        let (id, _) = try await acceptedThread(fx)
        let bare = try await addOrigin(fx)

        let first = try await ship(["--yes"], fx: fx, gh: gh)
        #expect(first.code == 0, "\(first.text)")
        #expect(first.lines.last == "https://github.com/o/r/pull/12")
        #expect(first.text.contains("shipping \(id)") && first.text.contains("workbench/\(id)"))
        #expect(try await branches(bare, fx).contains("refs/heads/workbench/\(id)"))
        let opened = try fx.events(id).filter { $0.kind == .prOpened }
        #expect(opened.count == 1 && opened[0].data["number"]?.intValue == 12)

        let again = try await ship(["--yes", id], fx: fx, gh: gh)
        #expect(again.code == 11, "\(again.text)")
        #expect(again.lines.last == "https://github.com/o/r/pull/12")
        #expect(gh.count("pr create") == 1)
    }

    @Test func withoutATerminalOrYesItShowsThePlanAndPushesNothing() async throws {
        let fx = try await RunnerFixture()
        let gh = try FakeGH(in: fx)
        let (id, _) = try await acceptedThread(fx)
        let bare = try await addOrigin(fx)

        let result = try await ship([], fx: fx, gh: gh)
        #expect(result.code == 6, "\(result.text)")
        #expect(result.text.contains("branch:  workbench/\(id)") && result.text.contains("Pass --yes"))
        #expect(try await branches(bare, fx).isEmpty)
        #expect(gh.count("pr create") == 0)
    }

    @Test func aThreadThatIsNotAcceptedExitsThree() async throws {
        let fx = try await RunnerFixture()
        let gh = try FakeGH(in: fx)
        let unknown = try await ship(["--yes", "g-nope"], fx: fx, gh: gh)
        #expect(unknown.code == 10, "\(unknown.text)")

        let none = try await ship(["--yes"], fx: fx, gh: gh)
        #expect(none.code == 10, "\(none.text)")
        #expect(none.text.contains("workbench accept"))
        #expect(none.text.contains("no accepted thread"))

        let id = try await fx.approvedThread()
        _ = try await fx.runner(id).run(fx.options())
        let bare = try await addOrigin(fx)
        let active = try await ship(["--yes", id], fx: fx, gh: gh)
        #expect(active.code == 10, "\(active.text)")
        #expect(active.text.contains("workbench accept"), "an active thread is told how to end it")
        #expect(try await branches(bare, fx).isEmpty)
    }

    @Test func aRejectedPushExitsFiveAndTheNextRunCompletes() async throws {
        let fx = try await RunnerFixture()
        let gh = try FakeGH(in: fx)
        let (id, _) = try await acceptedThread(fx)
        let bare = try await addOrigin(fx)
        let hook = bare.appendingPathComponent("hooks/pre-receive")
        try FileManager.default.createDirectory(at: hook.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\necho 'closed for release' >&2\nexit 1\n".write(to: hook, atomically: true, encoding: .utf8)
        chmod(hook.path, 0o755)

        let rejected = try await ship(["--yes"], fx: fx, gh: gh)
        #expect(rejected.code == 12, "\(rejected.text)")
        #expect(rejected.text.contains("closed for release"))
        #expect(try await branches(bare, fx).isEmpty)
        #expect(!(try fx.events(id).contains { $0.kind == .prOpened }))

        try FileManager.default.removeItem(at: hook)
        let done = try await ship(["--yes"], fx: fx, gh: gh)
        #expect(done.code == 0, "\(done.text)")
        #expect(gh.count("pr create") == 1)
    }

    @Test func aFailedPRAfterAPushIsResumedWithoutASecondPR() async throws {
        let fx = try await RunnerFixture()
        let gh = try FakeGH(in: fx)
        let (id, _) = try await acceptedThread(fx)
        let bare = try await addOrigin(fx)
        try gh.put("fail", "server error\n")

        let failed = try await ship(["--yes"], fx: fx, gh: gh)
        #expect(failed.code == 1, "\(failed.text)")
        #expect(try await branches(bare, fx).contains("workbench/\(id)"), "the push had happened")
        #expect(!(try fx.events(id).contains { $0.kind == .prOpened }))

        try FileManager.default.removeItem(at: gh.dir.appendingPathComponent("fail"))
        let resumed = try await ship(["--yes"], fx: fx, gh: gh)
        #expect(resumed.code == 0, "\(resumed.text)")
        #expect(resumed.text.contains("origin already has workbench/\(id)"))
        #expect(gh.count("pr create") == 2, "one that failed, one that worked")
        #expect(try fx.events(id).filter { $0.kind == .prOpened }.count == 1)
    }

    @Test func withoutAnIdTheNewestAcceptedThreadIsShipped() async throws {
        let fx = try await RunnerFixture()
        let gh = try FakeGH(in: fx)
        let (older, _) = try await acceptedThread(fx)
        // The slot is free after accept, so a second thread can be accepted too.
        try await Task.sleep(nanoseconds: 1_100_000_000)
        let newer = try await fx.approvedThread("second")
        _ = try await fx.runner(newer).run(fx.options())
        let worktree = fx.project.worktreesDirectory.appendingPathComponent(newer)
        try "two\n".write(to: worktree.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        try await fx.service.accept(id: newer, message: "chore: second")
        _ = try await addOrigin(fx)

        let result = try await ship(["--yes"], fx: fx, gh: gh)
        #expect(result.code == 0, "\(result.text)")
        #expect(result.text.contains("shipping \(newer)"))
        #expect(!(try fx.events(older).contains { $0.kind == .prOpened }))
        #expect(try fx.events(newer).contains { $0.kind == .prOpened })
    }

    @Test func aDivergedOriginExitsFiveAndPushesNothing() async throws {
        let fx = try await RunnerFixture()
        let gh = try FakeGH(in: fx)
        let (id, _) = try await acceptedThread(fx)
        let bare = try await addOrigin(fx)
        let other = fx.repo.deletingLastPathComponent().appendingPathComponent("clone-\(UUID().uuidString)")
        _ = try await fx.git.run(["clone", "-q", bare.path, other.path], in: fx.repo)
        _ = try await fx.git.run(["checkout", "-q", "-b", "x"], in: other)
        try "z\n".write(to: other.appendingPathComponent("z.txt"), atomically: true, encoding: .utf8)
        _ = try await fx.git.run(["add", "-A"], in: other)
        _ = try await fx.git.run(["commit", "-q", "-m", "other"], in: other)
        _ = try await fx.git.run(["push", "-q", bare.path, "HEAD:refs/heads/workbench/\(id)"], in: other)
        let before = try await branches(bare, fx)

        let result = try await ship(["--yes"], fx: fx, gh: gh)
        #expect(result.code == 12, "\(result.text)")
        #expect(result.text.contains("remove or rename"))
        #expect(try await branches(bare, fx) == before)
        #expect(gh.count("pr create") == 0)
    }

    @Test func aMissingGHIsReportedBeforeAnythingIsPushed() async throws {
        let fx = try await RunnerFixture()
        let gh = try FakeGH(in: fx)
        _ = try await acceptedThread(fx)
        let bare = try await addOrigin(fx)

        let result = try await ship(["--yes"], fx: fx, gh: gh, withGH: false)
        #expect(result.code == 6, "\(result.text)")
        #expect(result.text.contains("not-found") == false && result.text.contains("gh"))
        #expect(try await branches(bare, fx).isEmpty)
    }

    @Test func watchFollowsTheChecksAfterShippingAndOnAnAlreadyShippedThread() async throws {
        let fx = try await RunnerFixture()
        let gh = try FakeGH(in: fx)
        let (id, _) = try await acceptedThread(fx)
        _ = try await addOrigin(fx)
        try gh.put("checks_1", "[{\"name\": \"build\", \"bucket\": \"pending\"}]")
        try gh.put("checks_last", "[{\"name\": \"build\", \"bucket\": \"pass\"}]")

        let first = try await ship(["--yes", "--watch", "--interval", "1"], fx: fx, gh: gh)
        #expect(first.code == 0, "\(first.text)")
        #expect(first.text.contains("all checks passed") && first.text.contains("checks: 0 passed, 1 pending"))
        #expect(gh.count("pr create") == 1)

        // Already shipped: it is followed, and neither creates nor exits 4.
        try FileManager.default.removeItem(at: gh.dir.appendingPathComponent("checks_n"))
        let again = try await ship(["--yes", "--watch", "--interval", "1", id], fx: fx, gh: gh)
        #expect(again.code == 0, "\(again.text)")
        let nameless = try await ship(["--yes", "--watch", "--interval", "1"], fx: fx, gh: gh)
        #expect(nameless.code == 0, "\(nameless.text)")
        #expect(gh.count("pr create") == 1)
        #expect(try fx.events(id).filter { $0.kind == .prOpened }.count == 1)
    }

    @Test func aFailedCheckExitsSixAndBadWatchOptionsAreUsageErrors() async throws {
        let fx = try await RunnerFixture()
        let gh = try FakeGH(in: fx)
        _ = try await acceptedThread(fx)
        _ = try await addOrigin(fx)
        try gh.put("checks_last", "[{\"name\": \"build\", \"bucket\": \"fail\"}]")

        let failed = try await ship(["--yes", "--watch", "--interval", "1"], fx: fx, gh: gh)
        #expect(failed.code == 13, "\(failed.text)")
        #expect(failed.text.contains("fail") && failed.text.contains("build"))

        for bad in [["--timeout", "5"], ["--watch", "--interval", "0"], ["--watch", "--timeout", "999"]] {
            let result = try await ship(["--yes"] + bad, fx: fx, gh: gh)
            #expect(result.code == 2, "\(bad): \(result.text)")
        }
    }

    @Test func watchNeverSwapsANamedThreadForAnotherOne() async throws {
        let fx = try await RunnerFixture()
        let gh = try FakeGH(in: fx)
        let shipped = try await acceptedThread(fx)
        _ = try await addOrigin(fx)
        try gh.put("checks_last", "[{\"name\": \"build\", \"bucket\": \"pass\"}]")
        #expect(try await ship(["--yes"], fx: fx, gh: gh).code == 0)
        let before = gh.count("pr checks")

        let typo = try await ship(["--yes", "--watch", "g-typo"], fx: fx, gh: gh)
        #expect(typo.code == 10, "\(typo.text)")
        #expect(gh.count("pr checks") == before, "no other thread's PR was watched")

        // A name that is a path to a thread directory, not a thread id, is never used to read a log.
        let sneaky = try await ship(["--yes", "--watch", "../threads/\(shipped.id)"], fx: fx, gh: gh)
        #expect(sneaky.code == 10, "\(sneaky.text)")
        #expect(!sneaky.text.contains("watching"), "\(sneaky.text)")
        #expect(gh.count("pr checks") == before)

        // A named thread that was never accepted has no PR to watch: refused, with the way to end it.
        let active = try await fx.approvedThread("second")
        let notYet = try await ship(["--yes", "--watch", active], fx: fx, gh: gh)
        #expect(notYet.code == 10 && notYet.text.contains("workbench accept"), "\(notYet.text)")
        #expect(try fx.events(shipped.id).contains { $0.kind == .prOpened })
    }

    @Test func anUnknownOptionIsAUsageError() async throws {
        let fx = try await RunnerFixture()
        let result = try await ship(["--bogus"], fx: fx, gh: nil)
        #expect(result.code == 2, "\(result.text)")
    }
}
