import Foundation
import Testing

@testable import WorkbenchCore

/// A repository whose committed `check.sh` is the project's check.
private func fixture(script: String) async throws -> (RunnerFixture, String) {
    let fx = try await RunnerFixture(extraConfig: "check_command = \"./check.sh\"")
    let url = fx.repo.appendingPathComponent("check.sh")
    try ("#!/bin/sh\n" + script + "\n").write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    _ = try await fx.git.run(["add", "-A"], in: fx.repo)
    _ = try await fx.git.run(["commit", "-q", "-m", "add check"], in: fx.repo)
    return (fx, try await fx.approvedThread())
}

private func waitFor(_ path: String, timeout: TimeInterval = 20) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if FileManager.default.fileExists(atPath: path) { return true }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return false
}

@Suite struct CheckFollowUpTests {
    @Test func aFailedResumeAttemptIsNotCheckedAndTheRetryIs() async throws {
        let (fx, id) = try await fixture(script: "echo ok")
        let sessions = FakeClaude.scratch("sessions")
        defer { try? FileManager.default.removeItem(atPath: sessions) }
        let sessionID = UUID().uuidString.lowercased()
        try ThreadStore(project: fx.project).save(.init(sessionID: sessionID, confirmed: false), for: id)

        _ = try await fx.runner(id).run(fx.options("sessions=\(sessions)"))

        let events = try fx.events(id)
        #expect(ended(events).map { $0.data["result"]?.stringValue } == ["failed", "succeeded"])
        let checks = events.filter { $0.kind == .checkStarted || $0.kind == .checkRan }
        #expect(checks.map(\.kind.rawValue) == ["check.started", "check.ran"], "one check for the run")
        #expect(checks.allSatisfy { $0.turn == 2 }, "and it is the retry's, the turn that did the work")
    }

    @Test func outputThatCannotBeKeptIsNotAPass() {
        #expect(CheckRunner.finalResult(.passed, error: "the output file could not be written in full") == .failed)
        #expect(CheckRunner.finalResult(.passed, error: nil) == .passed)
        #expect(CheckRunner.finalResult(.timedOut, error: "x") == .timedOut)
        #expect(CheckRunner.finalResult(.failed, error: nil) == .failed)
    }

    @Test func anUnwritableOutputFileIsAFailureWithTheReason() async throws {
        let (fx, id) = try await fixture(script: "echo evidence")
        // The output path points somewhere that cannot be created.
        let out = fx.project.checkOutputURL(id, turn: 1)
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: out.path, withDestinationPath: "/nonexistent-dir/never/log")

        _ = try await fx.runner(id).run(fx.options("stream-events=1"))
        let ran = try #require(try fx.events(id).last { $0.kind == .checkRan })
        #expect(ran.data["result"]?.stringValue == "failed")
        #expect(ran.data["error"]?.stringValue?.contains("output file") == true)
    }

    @Test func oneLongLineSaysHowLongItWas() async throws {
        let (fx, id) = try await fixture(script: "head -c 3000000 /dev/zero | tr '\\0' 'x'; echo; echo after")
        _ = try await fx.runner(id).run(fx.options("stream-events=1"))
        let output = try String(contentsOf: fx.project.checkOutputURL(id, turn: 1), encoding: .utf8)
        #expect(output.contains("[line of 3000000 bytes, first 4096 kept]"))
        #expect(output.hasSuffix("[output truncated at 1048576 bytes]\n"))
    }

    @Test func followingWhileACheckRunsEndsWhenTheCheckDoes() async throws {
        let go = FakeClaude.scratch("go")
        let started = FakeClaude.scratch("check-started")
        defer {
            try? FileManager.default.removeItem(atPath: go)
            try? FileManager.default.removeItem(atPath: started)
        }
        let (fx, id) = try await fixture(
            script: "touch \(started); while [ ! -f \(go) ]; do sleep 0.1; done")
        let runner = fx.runner(id)
        let options = fx.options("stream-events=1")
        let running = Task { try await runner.run(options) }
        #expect(await waitFor(started), "the check is open")

        var spawn = SpawnRequest(
            executable: WorkbenchBinary.executable, arguments: ["log", "--follow"],
            environment: ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "USER": NSUserName()],
            workingDirectory: fx.repo, timeout: 40)
        spawn.snapshotInterval = 3600
        let follower = try ProcessRunner.start(spawn)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        FileManager.default.createFile(atPath: go, contents: nil)

        var exit: ProcessExit?
        for await event in follower.events { if case .exited(let e) = event { exit = e } }
        _ = try await running.value
        #expect(exit?.termination == .exited(0), "it returned instead of waiting for ever")
        #expect(exit?.cause == .natural)
    }
}
