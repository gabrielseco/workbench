import Foundation
import Testing

@testable import WorkbenchCore

private func alive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

private func waitUntilGone(_ pid: pid_t, timeout: TimeInterval = 8) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if !alive(pid) { return true }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return !alive(pid)
}

/// A stand-in app: prints its ready line, leaves a child, and records what it was given.
private let readyApp = """
    #!/bin/sh
    sleep 300 &
    echo $! > child.pid
    echo $$ > app.pid
    env > app.env
    echo "the app is ready on $WORKBENCH_PORT"
    wait
    """

private let runTable = "[run]\ncommand = \"scripts/app.sh\"\nready_line = \"is ready on [0-9]+\"\nready_timeout_s = 10"

private func fixture(
    _ app: String = readyApp, table: String = runTable, verifier: String = ""
) async throws -> VerifierFixture {
    try await VerifierFixture(verifier: verifier, run: table, files: ["scripts/app.sh": app])
}

private func pid(_ v: VerifierFixture, _ name: String) throws -> pid_t {
    let text = try String(contentsOf: v.worktree.appendingPathComponent(name), encoding: .utf8)
    return try #require(pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)))
}

private final class StopHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var runs: [ProcessRun] = []
    func attach(_ run: ProcessRun) { lock.withLock { runs.append(run) } }
    func stop() { lock.withLock { runs }.forEach { $0.stop() } }
    func waitForRun() async -> Bool {
        let deadline = Date().addingTimeInterval(Patience.limit)
        while Date() < deadline {
            if lock.withLock({ !runs.isEmpty }) { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return false
    }
}

@Suite(.processGate) struct RunLaunchTests {
    // MARK: Launch

    @Test func theAppIsUpBeforeTheVerifierStartsAndTheVerifierIsToldAboutIt() async throws {
        let v = try await fixture()
        let dump = FakeClaude.scratch("run-dump")
        defer { try? FileManager.default.removeItem(atPath: dump) }
        let report = try await v.verify("dump=\(dump),proof=shot.png")
        #expect(report.ok)

        let info = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: dump))) as? [String: Any])
        let env = try #require(info["env"] as? [String: String])
        let app = try pid(v, "app.pid")
        #expect(env["WORKBENCH_RUN_PID"] == String(app))
        let port = try #require(env["WORKBENCH_PORT"].flatMap(Int.init))
        #expect(env["PORT"] == String(port) && port > 0)
        #expect(env["WORKBENCH_RUN_URL"] == nil, "a line check has no URL")
        let argv = try #require(info["argv"] as? [String])
        let prompt = try #require(argv.last)
        #expect(prompt.contains("WORKBENCH_RUN_PID=\(app)") && prompt.contains("WORKBENCH_PORT=\(port)"))
        #expect(prompt.contains("has already started the project's app"))

        // What the app saw: a free port as both variables, the thread, and no credentials.
        let seen = try String(contentsOf: v.worktree.appendingPathComponent("app.env"), encoding: .utf8)
        #expect(seen.contains("WORKBENCH_PORT=\(port)") && seen.contains("PORT=\(port)"))
        #expect(seen.contains("WORKBENCH_THREAD=\(v.id)") && !seen.contains("GITHUB_TOKEN"))
    }

    @Test func aProjectWithNoRunTellsTheVerifierNothingAboutAnApp() async throws {
        let v = try await VerifierFixture()
        let dump = FakeClaude.scratch("norun-dump")
        defer { try? FileManager.default.removeItem(atPath: dump) }
        _ = try await v.verify("dump=\(dump),proof=shot.png")
        let info = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: dump))) as? [String: Any])
        let env = try #require(info["env"] as? [String: String])
        #expect(env["WORKBENCH_RUN_PID"] == nil && env["WORKBENCH_PORT"] == nil)
        let prompt = try #require((info["argv"] as? [String])?.last)
        #expect(!prompt.contains("WORKBENCH_RUN") && !prompt.contains("## The app"))
        #expect(try v.fx.events(v.id).filter { $0.kind == .runStarted || $0.kind == .runEnded }.isEmpty)
    }

    @Test func aUrlCheckIsFilledWithThePortAndPassedOn() async throws {
        try #require(FileManager.default.isExecutableFile(atPath: "/usr/bin/python3"))
        let app = """
            #!/bin/sh
            echo $$ > app.pid
            exec python3 -m http.server "$WORKBENCH_PORT" --bind 127.0.0.1
            """
        let table = "[run]\ncommand = \"scripts/app.sh\"\nready_url = \"http://127.0.0.1:{port}/\"\nready_timeout_s = 90"
        let v = try await fixture(app, table: table)
        let dump = FakeClaude.scratch("run-url-dump")
        defer { try? FileManager.default.removeItem(atPath: dump) }
        let report = try await v.verify("dump=\(dump),proof=shot.png")
        #expect(report.ok)
        let info = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: dump))) as? [String: Any])
        let env = try #require(info["env"] as? [String: String])
        let url = try #require(env["WORKBENCH_RUN_URL"])
        #expect(url.hasPrefix("http://127.0.0.1:") && url.hasSuffix("/") && !url.contains("{port}"))
        let prompt = try #require((info["argv"] as? [String])?.last)
        #expect(prompt.contains("WORKBENCH_RUN_URL=\(url)"))
        #expect(await waitUntilGone(try pid(v, "app.pid")), "the server is still running")
    }

    @Test func aRedirectingServerThatNeverEndsItsBodyIsStillReadyAtItsHeaders() async throws {
        try #require(FileManager.default.isExecutableFile(atPath: "/usr/bin/python3"))
        // A 302 to an address that must never be contacted, then a body that does not end: the check takes the answer
        // at the headers, does not follow the redirect and does not read on.
        let server = """
            import http.server, sys
            class H(http.server.BaseHTTPRequestHandler):
                def do_GET(self):
                    self.send_response(302)
                    self.send_header("Location", "http://203.0.113.1:9/")
                    self.end_headers()
                    try:
                        while True:
                            self.wfile.write(b"x" * 65536)
                    except OSError:
                        pass
                def log_message(self, *args): pass
            http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
            """
        let app = """
            #!/bin/sh
            echo $$ > app.pid
            exec python3 scripts/server.py "$WORKBENCH_PORT"
            """
        let table = "[run]\ncommand = \"scripts/app.sh\"\nready_url = \"http://127.0.0.1:{port}/\"\nready_timeout_s = 90"
        let v = try await VerifierFixture(run: table, files: ["scripts/app.sh": app, "scripts/server.py": server])
        // Ready within `ready_timeout_s` is the proof: a check that waited on the body would end the turn as not ready.
        let report = try await v.verify("proof=shot.png")
        #expect(report.ok, "\(report.reason ?? "")")
        let ended = try #require(try v.fx.events(v.id).first { $0.kind == .runEnded }).data
        #expect(ended["ready"] == true)
        #expect(await waitUntilGone(try pid(v, "app.pid")))
    }

    // MARK: Events

    @Test func theLogHasOneRunStartedAndOneRunEndedBetweenTheVerifierEvents() async throws {
        let v = try await fixture()
        let report = try await v.verify("proof=shot.png")
        #expect(report.ok)
        let kinds = try v.fx.events(v.id).map(\.kind.rawValue).filter {
            ["verifier.started", "run.started", "run.ended", "verifier.ended"].contains($0)
        }
        #expect(kinds == ["verifier.started", "run.started", "run.ended", "verifier.ended"], "\(kinds)")
        #expect(try v.fx.contents(v.id).isHealthy)
        let events = try v.fx.events(v.id)
        let started = try #require(events.first { $0.kind == .runStarted }).data
        #expect(started["command"]?.stringValue == "scripts/app.sh" && started["port"]?.intValue != nil)
        #expect(started["ready_line"]?.stringValue == "is ready on [0-9]+")
        let ended = try #require(events.first { $0.kind == .runEnded }).data
        #expect(ended["ready"] == true && ended["ready_ms"]?.intValue != nil && ended["exited_early"] == false)
        #expect(ended["signal"]?.intValue != nil || ended["exit_code"]?.intValue != nil)
    }

    // MARK: Everything it started goes with the turn

    @Test func theAppAndItsChildAreEndedWhenTheTurnEnds() async throws {
        let v = try await fixture()
        _ = try await v.verify("proof=shot.png")
        #expect(await waitUntilGone(try pid(v, "app.pid")), "the app is still running")
        #expect(await waitUntilGone(try pid(v, "child.pid")), "the app's child is still running")
    }

    @Test func aVerifierTimeoutStillEndsTheApp() async throws {
        let v = try await fixture()
        let report = try await v.verify("hang-after=1", timeout: 1)
        #expect(!report.ok && report.reason?.contains("did not finish within 1s") == true)
        #expect(await waitUntilGone(try pid(v, "app.pid")))
        #expect(await waitUntilGone(try pid(v, "child.pid")))
        try v.expectPairedRun()
    }

    @Test(arguments: ["crash-after=1", "die-after=1"])
    func aVerifierThatCrashesStillEndsTheApp(directive: String) async throws {
        let v = try await fixture()
        let report = try await v.verify(directive)
        #expect(!report.ok)
        #expect(await waitUntilGone(try pid(v, "app.pid")))
        #expect(await waitUntilGone(try pid(v, "child.pid")))
        try v.expectPaired(1)
        try v.expectPairedRun()
    }

    @Test func aStopDuringTheVerifierEndsTheApp() async throws {
        let v = try await fixture()
        let holder = StopHolder()
        let task = Task { try await v.verify("hang-after=1", timeout: 30, attach: { holder.attach($0) }) }
        // The app's own process is attached first; the verifier's `claude` follows it.
        let deadline = Date().addingTimeInterval(Patience.limit)
        while Date() < deadline, !FileManager.default.fileExists(atPath: v.worktree.appendingPathComponent("child.pid").path) {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        try await Task.sleep(nanoseconds: 1_500_000_000)
        holder.stop()
        let report = try await task.value
        #expect(!report.ok)
        #expect(await waitUntilGone(try pid(v, "app.pid")))
        #expect(await waitUntilGone(try pid(v, "child.pid")))
        try v.expectPairedRun()
    }

    @Test func anAppThatIgnoresSIGTERMIsKilledAndItsChildrenSwept() async throws {
        let app = """
            #!/bin/sh
            trap '' TERM
            sleep 300 &
            echo $! > child.pid
            echo $$ > app.pid
            echo "the app is ready on $WORKBENCH_PORT"
            while :; do sleep 1; done
            """
        let v = try await fixture(app)
        let report = try await v.verify("proof=shot.png", grace: 0.5)
        #expect(report.ok)
        #expect(await waitUntilGone(try pid(v, "app.pid")))
        #expect(await waitUntilGone(try pid(v, "child.pid")))
        let ended = try #require(try v.fx.events(v.id).first { $0.kind == .runEnded }).data
        #expect(ended["escalated_to_kill"] == true)
    }

    // MARK: Failures spend nothing

    @Test(arguments: [
        ("#!/bin/sh\necho starting\necho dying >&2\nexit 3\n", "the app ended before it was ready (exit 3)", "dying"),
        ("#!/bin/sh\necho still starting\nsleep 300\n", "the app was not ready within 3s", "still starting"),
    ])
    func anAppThatNeverComesUpEndsTheTurnWithAReasonAndNeverStartsTheVerifier(
        app: String, reason: String, tail: String
    ) async throws {
        let table = "[run]\ncommand = \"scripts/app.sh\"\nready_line = \"never printed\"\nready_timeout_s = 3"
        let v = try await fixture(app, table: table)
        let dump = FakeClaude.scratch("run-fail-dump")
        defer { try? FileManager.default.removeItem(atPath: dump) }
        let report = try await v.verify("dump=\(dump),proof=shot.png")
        #expect(!report.ok && report.reason == reason, "\(report.reason ?? "nil")")
        #expect(report.costUSD == nil)
        #expect(!FileManager.default.fileExists(atPath: dump), "claude must not have been started")
        try v.expectPaired(1)
        try v.expectPairedRun()
        let ended = try #require(try v.fx.events(v.id).first { $0.kind == .runEnded }).data
        #expect(ended["ready"] == false && ended["reason"]?.stringValue == reason)
        #expect(ended["duration_ms"]?.intValue != nil, "every failed start says how long it took")
        if reason.contains("ended before") { #expect(ended["exit_code"]?.intValue == 3 && ended["duration_ms"]?.intValue != nil) }
        guard case .array(let lines)? = ended["tail"] else { Issue.record("tail missing"); return }
        #expect(lines.compactMap(\.stringValue).contains { $0.contains(tail) })
    }

    @Test func aCommandThatIsNotThereEndsTheTurnWithAReason() async throws {
        let table = "[run]\ncommand = \"scripts/missing.sh\"\nready_line = \"x\""
        let v = try await fixture(table: table)
        let report = try await v.verify("proof=shot.png")
        #expect(!report.ok && report.reason == "the [run] command 'scripts/missing.sh' was not found")
        try v.expectPaired(1)
        try v.expectPairedRun()
    }

    // MARK: Where the command comes from

    @Test func theCommandIsTheProjectsConfigNotAFileTheRunCanEdit() async throws {
        let v = try await fixture()
        // A coding run can only write in the worktree; its copy of the config is not read.
        let inWorktree = v.worktree.appendingPathComponent(".workbench/config.toml")
        try FileManager.default.createDirectory(at: inWorktree.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "[run]\ncommand = \"scripts/evil.sh\"\nready_line = \"x\"\n".write(to: inWorktree, atomically: true, encoding: .utf8)
        _ = try await v.verify("proof=shot.png")
        let started = try #require(try v.fx.events(v.id).first { $0.kind == .runStarted }).data
        #expect(started["command"]?.stringValue == "scripts/app.sh")
    }
}

extension VerifierFixture {
    /// Every `run.started` has exactly one `run.ended` after it.
    func expectPairedRun(sourceLocation: SourceLocation = #_sourceLocation) throws {
        let kinds = try fx.events(id).map(\.kind.rawValue).filter { $0.hasPrefix("run.") }
        #expect(kinds == ["run.started", "run.ended"], "\(kinds)", sourceLocation: sourceLocation)
    }
}

@Suite(.processGate) struct RunRecoveryTests {
    @Test func anAppLeftOpenByADeadRunnerIsClosedBeforeTheVerifierIs() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wb-runlog-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let log = try EventLogWriter.open(at: url)
        try await log.append(.verifierStarted, turn: 2, data: ["argv": ["claude"]])
        try await log.append(.runStarted, turn: 2, data: ["command": "scripts/app.sh", "port": 4000])
        try await log.recoverOrphanedVerifier()
        await log.close()

        let events = try EventLogReader.read(at: url).events
        #expect(events.map(\.kind.rawValue) == ["verifier.started", "run.started", "run.ended", "verifier.ended"])
        #expect(events[2].data["synthetic"] == true && events[2].data["reason"] == "interrupted")
        #expect(events[2].turn == 2)
    }
}
