import Foundation
import Testing

@testable import WorkbenchCore

/// Locates and drives the `fake-claude` test double. Shared by the runner tests in later tasks.
enum FakeClaude {
    static let executable: URL = {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var candidates = [".build/debug/fake-claude", ".build/release/fake-claude"].map {
            root.appendingPathComponent($0)
        }
        // Next to the test bundle, whatever the configuration and architecture.
        for bundle in Bundle.allBundles where bundle.bundleURL.pathExtension == "xctest" {
            candidates.insert(
                bundle.bundleURL.deletingLastPathComponent().appendingPathComponent("fake-claude"), at: 0)
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) } ?? candidates[0]
    }()

    static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("docs/plan/P1-spikes/fixtures")

    static func fixture(_ name: String) -> String { fixtures.appendingPathComponent(name).path }

    static func environment(_ directives: String...) -> [String: String] {
        ["FAKE_CLAUDE": directives.joined(separator: ","), "PATH": "/usr/bin:/bin"]
    }

    /// Runs the fake to completion with the generic bounded runner and returns its output lines.
    static func run(
        _ directives: String..., arguments: [String] = ["-p", "--", "hi"], timeout: TimeInterval = 10
    ) async throws -> (result: GitResult, lines: [String]) {
        let runner = GitRunner(
            executable: executable, environment: environment(directives.joined(separator: ",")),
            timeout: timeout)
        let result = try await runner.run(arguments, in: URL(fileURLWithPath: "/tmp"))
        return (result, result.stdout.split(separator: "\n").map(String.init))
    }

    static func environment(_ joined: String) -> [String: String] {
        ["FAKE_CLAUDE": joined, "PATH": "/usr/bin:/bin"]
    }

    static func object(_ line: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }

    static func scratch(_ name: String) -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("fc-\(UUID().uuidString)-\(name)").path
    }

    static func alive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

    static func waitUntilGone(_ pid: pid_t, within seconds: TimeInterval = 3) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if !alive(pid) { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return !alive(pid)
    }
}

@Suite struct FakeClaudeTests {
    @Test func theBinaryIsBuiltAndRunnable() {
        #expect(FileManager.default.isExecutableFile(atPath: FakeClaude.executable.path))
    }

    @Test func defaultTurnIsInitAssistantResultAndEchoesSessionAndPrompt() async throws {
        let (result, lines) = try await FakeClaude.run(
            arguments: ["-p", "--session-id", "11111111-2222-3333-4444-555555555555", "--", "do the thing"])
        #expect(result.status == 0)
        #expect(lines.count == 3)
        let objects = try lines.map(FakeClaude.object)
        #expect(objects.map { $0["type"] as? String } == ["system", "assistant", "result"])
        #expect(objects.allSatisfy { $0["session_id"] as? String == "11111111-2222-3333-4444-555555555555" })
        #expect(objects[2]["result"] as? String == "fake claude: do the thing")
        #expect(objects[2]["subtype"] as? String == "success")
    }

    @Test func resumeUsesTheGivenSessionID() async throws {
        let (_, lines) = try await FakeClaude.run(arguments: ["-p", "--resume", "aaaa", "--", "x"])
        #expect(try FakeClaude.object(lines[0])["session_id"] as? String == "aaaa")
    }

    @Test func replaysARecordedRunWithTheSessionIDRewritten() async throws {
        let fixture = FakeClaude.fixture("s1-read-2.jsonl")
        let recorded = try String(contentsOfFile: fixture, encoding: .utf8).split(separator: "\n").map(String.init)
        let (result, lines) = try await FakeClaude.run(
            "fixture=\(fixture)", arguments: ["-p", "--resume", "my-session", "--", "x"])

        #expect(result.status == 0)
        #expect(lines.count == recorded.count)
        #expect(try FakeClaude.object(lines.last!)["type"] as? String == "result")
        #expect(lines.allSatisfy { !$0.contains("\"session_id\":\"\(try! oldSession(recorded))\"") })
        #expect(lines.contains { $0.contains("\"session_id\":\"my-session\"") })
    }

    private func oldSession(_ lines: [String]) throws -> String {
        let line = try #require(lines.first { $0.contains("\"session_id\":\"") })
        let range = try #require(line.range(of: #"(?<="session_id":")[^"]+"#, options: .regularExpression))
        return String(line[range])
    }

    @Test func exitCodeAndMissingResult() async throws {
        let failed = try await FakeClaude.run("exit=2")
        #expect(failed.result.status == 2)
        #expect(failed.lines.count == 3)

        let silent = try await FakeClaude.run("no-result")
        #expect(silent.result.status == 0)
        #expect(silent.lines.count == 2)
    }

    @Test func crashAndDieStopEarlyWithoutAResult() async throws {
        let crashed = try await FakeClaude.run("crash-after=1")
        #expect(crashed.result.status == 70)
        #expect(crashed.lines.count == 1)

        let died = try await FakeClaude.run("die-after=2")
        #expect(died.result.status == SIGKILL || died.result.status == 128 + SIGKILL || died.result.status != 0)
        #expect(died.lines.count == 2)
    }

    @Test func hangStopsEmittingAndTheRunnerTimeoutEndsIt() async throws {
        let started = Date()
        await #expect(throws: GitError.self) {
            _ = try await FakeClaude.run("hang-after=1", timeout: 0.5)
        }
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test func invalidLineAndFloodComeBeforeTheResult() async throws {
        let (_, lines) = try await FakeClaude.run("invalid-line", "flood=200000")
        #expect(lines.count == 5)
        #expect(lines[2] == "this is not json {" || lines[3] == "this is not json {")
        #expect(lines.contains { $0.utf8.count > 200_000 })
        #expect(try FakeClaude.object(lines.last!)["type"] as? String == "result")
    }

    @Test func partialTailLeavesNoTrailingNewline() async throws {
        let (result, _) = try await FakeClaude.run("partial-tail")
        #expect(!result.stdout.hasSuffix("\n"))
        #expect(result.stdout.hasSuffix("}"))
    }

    @Test func streamEventsAreInsertedBeforeTheAssistantLine() async throws {
        let (_, lines) = try await FakeClaude.run("stream-events=4")
        #expect(lines.count == 7)
        #expect(try FakeClaude.object(lines[1])["type"] as? String == "stream_event")
        #expect(try FakeClaude.object(lines[5])["type"] as? String == "assistant")
    }

    @Test func dumpReportsStdinArgvEnvironmentAndDescriptors() async throws {
        let file = FakeClaude.scratch("dump.json")
        defer { try? FileManager.default.removeItem(atPath: file) }
        let cwd = FileManager.default.temporaryDirectory
        let runner = GitRunner(
            executable: FakeClaude.executable,
            environment: ["FAKE_CLAUDE": "dump=\(file)", "PATH": "/usr/bin:/bin", "MARKER": "yes"], timeout: 10)
        _ = try await runner.run(["-p", "--restricted", "--", "the prompt"], in: cwd)

        let dump = try #require(
            JSONSerialization.jsonObject(with: try Data(contentsOf: URL(fileURLWithPath: file))) as? [String: Any])
        #expect(dump["stdin_eof"] as? Bool == true)
        #expect((dump["argv"] as? [String])?.last == "the prompt")
        #expect((dump["env"] as? [String: String])?["MARKER"] == "yes")
        #expect((dump["cwd"] as? String).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
            == cwd.resolvingSymlinksInPath().path)
        let fds = try #require(dump["fds"] as? [[String: Any]])
        let numbers = fds.compactMap { $0["fd"] as? Int }
        #expect(numbers.contains(0) && numbers.contains(1) && numbers.contains(2))
        #expect(fds.first { $0["fd"] as? Int == 0 }?["path"] as? String == "/dev/null")
    }

    @Test func sessionsAreTrackedLikeTheRealCLI() async throws {
        let dir = FakeClaude.scratch("sessions")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let id = "99999999-aaaa-bbbb-cccc-dddddddddddd"

        let first = try await FakeClaude.run("sessions=\(dir)", arguments: ["-p", "--session-id", id, "--", "a"])
        #expect(first.result.status == 0)

        let reuse = try await FakeClaude.run("sessions=\(dir)", arguments: ["-p", "--session-id", id, "--", "b"])
        #expect(reuse.result.status == 1)
        #expect(reuse.result.stderr.contains("already in use"))
        #expect(reuse.lines.isEmpty)

        let resume = try await FakeClaude.run("sessions=\(dir)", arguments: ["-p", "--resume", id, "--", "c"])
        #expect(resume.result.status == 0)

        let unknown = try await FakeClaude.run("sessions=\(dir)", arguments: ["-p", "--resume", "nope", "--", "d"])
        #expect(unknown.result.status == 1)
        #expect(unknown.lines.isEmpty)
    }
}

/// A running fake, driven explicitly. Tests signal it after `ready`, never after a guess about startup time.
/// Started through the same spawner as production code, so these tests cannot reintroduce the
/// fork-to-exec descriptor window that Foundation's `Process` has.
final class FakeProcess: @unchecked Sendable {
    private let run: ProcessRun
    private let lock = NSLock()
    private var status: (code: Int32, signaled: Bool)?
    private let readyFile = FakeClaude.scratch("ready")

    var pid: pid_t { run.pid }

    init(_ directives: String..., arguments: [String] = ["-p", "--", "hi"]) throws {
        let joined = (directives + ["ready=\(readyFile)"]).joined(separator: ",")
        var request = SpawnRequest(
            executable: FakeClaude.executable, arguments: arguments,
            environment: FakeClaude.environment(joined), workingDirectory: URL(fileURLWithPath: "/tmp"),
            timeout: 120)
        request.killGrace = 60  // signals are sent by the test, not by the runner
        run = try ProcessRunner.start(request)

        let events = run.events
        Task.detached { [self] in
            for await event in events {
                guard case .exited(let exit) = event else { continue }
                let mapped: (Int32, Bool)
                switch exit.termination {
                case .exited(let code): mapped = (code, false)
                case .signaled(let signal): mapped = (signal, true)
                case .lost: mapped = (-1, false)
                }
                lock.withLock { status = mapped }
            }
        }
    }

    deinit {
        kill(run.pid, SIGKILL)
        try? FileManager.default.removeItem(atPath: readyFile)
    }

    func waitReady(timeout: TimeInterval = 10) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: readyFile) { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return false
    }

    func send(_ signal: Int32) { kill(pid, signal) }

    /// How the process ended, or nil if it is still running after `timeout`.
    func exited(within timeout: TimeInterval) async -> (code: Int32, signaled: Bool)? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let current = currentStatus() { return current }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return currentStatus()
    }

    private func currentStatus() -> (code: Int32, signaled: Bool)? {
        lock.withLock { status }
    }
}

@Suite struct FakeClaudeSignalTests {
    @Test func ignoreTermSurvivesSigtermAndOnlySigkillEndsIt() async throws {
        let fake = try FakeProcess("ignore-term", "hang-after=1")
        #expect(await fake.waitReady())

        fake.send(SIGTERM)
        #expect(await fake.exited(within: 0.5) == nil, "SIGTERM must be ignored")

        fake.send(SIGKILL)
        let end = try #require(await fake.exited(within: 3))
        #expect(end.signaled)
        #expect(end.code == SIGKILL)
    }

    @Test func defaultSigtermStopsTheGrandchildAndExits143() async throws {
        let pidFile = FakeClaude.scratch("gc.pid")
        defer { try? FileManager.default.removeItem(atPath: pidFile) }
        let fake = try FakeProcess("grandchild=\(pidFile)", "hang-after=1")
        #expect(await fake.waitReady())
        let grandchild = try #require(pid_t(try String(contentsOfFile: pidFile, encoding: .utf8)))
        defer { kill(grandchild, SIGKILL) }
        #expect(FakeClaude.alive(grandchild))

        fake.send(SIGTERM)
        let end = try #require(await fake.exited(within: 3))
        #expect(!end.signaled)
        #expect(end.code == 143)
        #expect(await FakeClaude.waitUntilGone(grandchild), "SIGTERM handler should have stopped the grandchild")
    }

    @Test func grandchildIsInItsOwnProcessGroupAndSurvivesAHardKill() async throws {
        let pidFile = FakeClaude.scratch("gc.pid")
        let dumpFile = FakeClaude.scratch("dump.json")
        defer {
            try? FileManager.default.removeItem(atPath: pidFile)
            try? FileManager.default.removeItem(atPath: dumpFile)
        }

        // `die-after` SIGKILLs the fake, so nothing gets to clean up its child.
        _ = try await FakeClaude.run("grandchild=\(pidFile)", "dump=\(dumpFile)", "die-after=1")

        let pid = try #require(pid_t(try String(contentsOfFile: pidFile, encoding: .utf8)))
        defer { kill(pid, SIGKILL) }
        let dump = try #require(
            JSONSerialization.jsonObject(with: try Data(contentsOf: URL(fileURLWithPath: dumpFile))) as? [String: Any])
        let fakePGID = try #require(dump["pgid"] as? Int)

        #expect(FakeClaude.alive(pid), "an orphaned tool child outlives a SIGKILLed parent (spike S6)")
        #expect(getpgid(pid) == pid, "own process group")
        #expect(Int(getpgid(pid)) != fakePGID, "not the parent's group, so a group kill would miss it")
    }
}
