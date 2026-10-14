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
        #expect(again.code == 4, "\(again.text)")
        #expect(again.lines.last == "https://github.com/o/r/pull/12")
        #expect(gh.count("pr create") == 1)
    }

    @Test func withoutATerminalOrYesItShowsThePlanAndPushesNothing() async throws {
        let fx = try await RunnerFixture()
        let gh = try FakeGH(in: fx)
        let (id, _) = try await acceptedThread(fx)
        let bare = try await addOrigin(fx)

        let result = try await ship([], fx: fx, gh: gh)
        #expect(result.code == 1, "\(result.text)")
        #expect(result.text.contains("branch:  workbench/\(id)") && result.text.contains("Pass --yes"))
        #expect(try await branches(bare, fx).isEmpty)
        #expect(gh.count("pr create") == 0)
    }

    @Test func aThreadThatIsNotAcceptedExitsThree() async throws {
        let fx = try await RunnerFixture()
        let gh = try FakeGH(in: fx)
        let none = try await ship(["--yes"], fx: fx, gh: gh)
        #expect(none.code == 3, "\(none.text)")
        #expect(none.text.contains("workbench accept"))

        let id = try await fx.approvedThread()
        _ = try await fx.runner(id).run(fx.options())
        let bare = try await addOrigin(fx)
        let active = try await ship(["--yes", id], fx: fx, gh: gh)
        #expect(active.code == 3, "\(active.text)")
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
        #expect(rejected.code == 5, "\(rejected.text)")
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
        #expect(try fx.events(id).filter { $0.kind == .prOpened }.count == 1)
    }

    @Test func aMissingGHIsReportedBeforeAnythingIsPushed() async throws {
        let fx = try await RunnerFixture()
        let gh = try FakeGH(in: fx)
        _ = try await acceptedThread(fx)
        let bare = try await addOrigin(fx)

        let result = try await ship(["--yes"], fx: fx, gh: gh, withGH: false)
        #expect(result.code == 1, "\(result.text)")
        #expect(result.text.contains("gh"))
        #expect(try await branches(bare, fx).isEmpty)
    }

    @Test func anUnknownOptionIsAUsageError() async throws {
        let fx = try await RunnerFixture()
        let result = try await ship(["--bogus"], fx: fx, gh: nil)
        #expect(result.code == 2, "\(result.text)")
    }
}
