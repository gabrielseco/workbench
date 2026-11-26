import Foundation
import Testing

@testable import WorkbenchCore

#if os(macOS)
    private let gatewayKey = "test-gateway-key-0123456789"

    // swiftlint:disable line_length
    /// An `opencode` that runs where a real one would, under `sandbox-exec` and behind the forwarder, and says what it saw in the
    /// event stream (which the runner records verbatim): the key variable's value, the status of a request through the forwarder,
    /// whether it could write outside its worktree, and its config's address. It edits `a.txt` in the worktree it starts in.
    /// `hang`, `ignoreterm`, `leftover`, `error` and `crash` in its folder change what it does.
    private func fakeOpencodeScript(_ dir: URL) -> String {
        """
        #!/bin/sh
        D="\(dir.path)"
        for a in "$@"; do p="$a"; done
        base=$(grep -o 'http://127.0.0.1:[0-9]*/[A-Za-z0-9/._-]*' "$OPENCODE_CONFIG" | head -1)
        code=$(/usr/bin/curl -s -m 10 -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer forwarder' "$base/models")
        echo x > "$D/escape.txt" 2>/dev/null; esc=$?
        echo '{"type":"step_start","sessionID":"ses_1","part":{"type":"step-start"}}'
        if [ -f "$D/hang" ]; then sleep 300 & echo '{"type":"text","sessionID":"ses_1","part":{"type":"text","text":"child='$!'"}}'; wait; fi
        if [ -f "$D/ignoreterm" ]; then trap '' TERM; sleep 300 & echo '{"type":"text","sessionID":"ses_1","part":{"type":"text","text":"child='$!'"}}'; wait; fi
        if [ -f "$D/error" ]; then
          # A finished step first, so that only the error that follows can make this turn fail.
          echo '{"type":"step_finish","sessionID":"ses_1","part":{"type":"step-finish","reason":"stop","cost":0.001,"tokens":{"input":1,"output":1}}}'
          echo '{"type":"error","sessionID":"ses_1","error":{"type":"provider.internal","message":"Service Unavailable","status":503}}'; exit 0
        fi
        if [ -f "$D/leftover" ]; then
          /usr/bin/perl -e 'setpgrp(0,0); exec "/bin/sleep", "300"' >/dev/null 2>&1 &
          echo '{"type":"text","sessionID":"ses_1","part":{"type":"text","text":"child='$!'"}}'; /bin/sleep 1
        fi
        echo "turn" >> a.txt
        if [ -f "$D/crash" ]; then echo boom >&2; exit 70; fi
        echo '{"type":"text","sessionID":"ses_1","part":{"type":"text","text":"key='$LITELLM_API_KEY' http='$code' escape='$esc' base='$base' cwd='$(pwd -P)'"}}'
        echo '{"type":"step_finish","sessionID":"ses_1","part":{"type":"step-finish","reason":"stop","cost":0.0123,"tokens":{"input":100,"output":9}}}'
        """
    }
    // swiftlint:enable line_length

    private struct OpencodeRun {
        let fx: RunnerFixture
        let dir: URL
        let id: String
        let gateway: FakeGateway

        func put(_ name: String) throws { try "".write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        var events: [Event] { (try? fx.events(id)) ?? [] }
        func ended() -> [Event] { events.filter { $0.kind == .turnEnded } }
        var hasWorktree: Bool {
            FileManager.default.fileExists(atPath: fx.project.worktreesDirectory.appendingPathComponent(id).path)
        }

        func options(_ configure: (inout RunOptions) -> Void = { _ in }) -> RunOptions {
            var o = fx.options("", timeout: 30)
            o.parentEnvironment["LITELLM_API_KEY"] = gatewayKey
            configure(&o)
            return o
        }

        func run(timeout: TimeInterval = 30, _ configure: (inout RunOptions) -> Void = { _ in }) async throws -> TurnReport {
            var o = options(configure)
            o.timeoutOverride = timeout
            return try await fx.runner(id).run(o)
        }

        /// What the fake printed, from the turn's recorded stream.
        func said() -> String {
            fx.transcript(id).compactMap { $0["part"]?["text"]?.stringValue }.joined(separator: "\n")
        }

        /// The pid of the background child the fake started in `hang` and `ignoreterm`, from what it said.
        func childPID() -> Int32? {
            guard let match = said().range(of: #"child=[0-9]+"#, options: .regularExpression) else { return nil }
            return Int32(said()[match].dropFirst("child=".count))
        }

        /// The address the forwarder had for the turn, from the config the runner wrote for it.
        func forwarderPort() throws -> Int {
            let config = fx.project.threadDirectory(id).appendingPathComponent("prompts/opencode/opencode.json")
            let text = try String(contentsOf: config, encoding: .utf8)
            let match = try #require(text.range(of: #"http://127\.0\.0\.1:[0-9]+"#, options: .regularExpression))
            return try #require(Int(text[match].split(separator: ":").last ?? ""))
        }
    }

    private func opencodeRun(
        extraConfig: String = "", goalEdit: (String) -> String = { $0 }, approve: Bool = true
    ) async throws -> OpencodeRun {
        let dir = Scratch.url("opencode-run", ext: "d")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("opencode")
        try fakeOpencodeScript(dir).write(to: script, atomically: true, encoding: .utf8)
        chmod(script.path, 0o755)
        let gateway = try FakeGateway()
        let fx = try await RunnerFixture(
            extraConfig: "[providers.opencode]\nbase_url = \"http://127.0.0.1:\(gateway.port)/v1\"\n"
                + "executable = \"\(script.path)\"\n[agents.run]\nprovider = \"opencode\"\n"
                + "model = \"sonnet-claude\"\n" + extraConfig)
        let id = try await fx.service.newThread(name: "work", base: "main")
        let url = fx.project.goalURL(id)
        var text = try String(contentsOf: url, encoding: .utf8)
        let fills = [
            ("TODO(workbench): say what should change, in a few sentences.", "Add a greeting to a.txt."),
            ("TODO(workbench): something that can be checked.", "a.txt contains the word hello."),
            ("TODO(workbench): how it will be shown (a test, a command, a screenshot).", "cat a.txt"),
            ("TODO(workbench): what must not change.", "Do not touch other files."),
        ]
        for (placeholder, value) in fills { text = text.replacingOccurrences(of: placeholder, with: value) }
        text = text.replacingOccurrences(
            of: #"budget_usd: [0-9.]+"#, with: "spend_policy: timeout_only", options: .regularExpression)
        text = goalEdit(text)
        try text.write(to: url, atomically: true, encoding: .utf8)
        if approve { try await fx.service.approve(id: id) }
        return OpencodeRun(fx: fx, dir: dir, id: id, gateway: gateway)
    }

    @Suite(.processGate) struct RunOpencodeTests {
        @Test func aCodingTurnRunsUnderTheSandboxBehindTheForwarderAndTheKeyNeverReachesTheAgent() async throws {
            let r = try await opencodeRun()
            defer { r.gateway.stop() }
            let report = try await r.run()
            #expect(report.result == .succeeded)
            let said = r.said()
            #expect(said.contains("key=forwarder"), "the agent holds a placeholder: \(said)")
            #expect(!said.contains(gatewayKey))
            #expect(said.contains("http=200"), "a request through the forwarder reached the gateway: \(said)")
            #expect(said.contains("escape=1"), "a write outside the worktree was refused: \(said)")
            let seen = try #require(r.gateway.requests.first)
            #expect(seen.headers["authorization"] == "Bearer \(gatewayKey)", "the forwarder added the real key")
            #expect(seen.target == "/v1/models")
            let worktree = r.fx.project.worktreesDirectory.appendingPathComponent(r.id)
            #expect(try String(contentsOf: worktree.appendingPathComponent("a.txt"), encoding: .utf8).contains("turn"))
            #expect(!FileManager.default.fileExists(atPath: r.dir.appendingPathComponent("escape.txt").path))
        }

        @Test func theLoggedCommandIsTheSandboxAndTheCostOfTheTurnIsRecorded() async throws {
            let r = try await opencodeRun()
            defer { r.gateway.stop() }
            _ = try await r.run()
            let started = try #require(r.events.first { $0.kind == .turnStarted })
            guard case .array(let items)? = started.data["argv"] else {
                Issue.record("no argv")
                return
            }
            let argv = items.compactMap(\.stringValue)
            #expect(argv.first == "/usr/bin/sandbox-exec" && argv.dropFirst().first == "-f", "\(argv)")
            #expect(argv.contains { $0.hasSuffix("/opencode") } && argv.contains("gateway/sonnet-claude"), "\(argv)")
            #expect(!argv.joined(separator: " ").contains(gatewayKey))
            #expect(started.data["session_id"] == nil, "a fresh process each turn: no session to name")
            let ended = try #require(r.ended().first)
            #expect(ended.data["result"] == "succeeded")
            #expect(ended.data["cost_usd"] == .double(0.0123), "the gateway's cost is on turn.ended")
        }

        /// True once nothing accepts connections on `port` any more (polled for up to five seconds).
        private func refusesConnections(_ port: Int) async throws -> Bool {
            for _ in 0..<100 {
                let probe = socket(AF_INET, SOCK_STREAM, 0)
                var address = sockaddr_in()
                address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                address.sin_family = sa_family_t(AF_INET)
                address.sin_port = UInt16(port).bigEndian
                address.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
                let connected = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        connect(probe, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                close(probe)
                if connected != 0 { return true }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            return false
        }

        @Test func theForwarderIsStoppedWhenTheTurnEndsWhateverWayItEnds() async throws {
            for how in ["", "crash"] {
                let r = try await opencodeRun()
                defer { r.gateway.stop() }
                if how == "crash" { try r.put("crash") }
                _ = try await r.run()
                let label = how.isEmpty ? "ok" : how
                #expect(try await refusesConnections(try r.forwarderPort()), "the forwarder still accepts connections (\(label))")
                if how == "crash" { #expect(r.ended().first?.data["result"] != "succeeded") }
            }
        }

        @Test func aTurnThatTimesOutIsEndedTheForwarderStoppedAndNothingLeftRunning() async throws {
            let r = try await opencodeRun()
            defer { r.gateway.stop() }
            try r.put("hang")
            let report = try await r.run(timeout: 3)
            // The fake reached its hang: it was started under the sandbox and printed its first event before it slept.
            let steps = r.fx.transcript(r.id).filter { $0["type"]?.stringValue == "step_start" }
            #expect(steps.count == 1, "the process ran and reached its hang, so the timeout is what ended it")
            #expect(report.result == .timedOut, "\(report.result)")
            let ended = try #require(r.ended().first)
            #expect(r.ended().count == 1, "one turn.ended per turn.started")
            #expect(ended.data["result"] == .string(RunResult.timedOut.rawValue), "and it says how it ended: \(ended.data)")
            let worktree = r.fx.project.worktreesDirectory.appendingPathComponent(r.id)
            #expect(OrphanSweeper.orphans(inside: worktree).isEmpty, "no process of the turn is left")
            let child = try #require(r.childPID(), "the fake started a background child")
            #expect(kill(child, 0) != 0, "and its child is gone")
            #expect(try await refusesConnections(try r.forwarderPort()), "and the forwarder is stopped")
        }

        @Test func aTurnThatIgnoresSigtermAndHasAChildIsKilledWithItsChildAndNothingIsLeftBehind() async throws {
            let r = try await opencodeRun()
            defer { r.gateway.stop() }
            try r.put("ignoreterm")
            let report = try await r.run(timeout: 3) { $0.killGrace = 1 }
            #expect(r.fx.transcript(r.id).filter { $0["type"]?.stringValue == "step_start" }.count == 1, "it reached its hang")
            #expect(report.result == .timedOut, "\(report.result)")
            let ended = try #require(r.ended().first)
            #expect(r.ended().count == 1, "one turn.ended per turn.started")
            #expect(ended.data["escalated_to_kill"] == .bool(true), "SIGTERM was ignored, so SIGKILL was needed: \(ended.data)")
            let child = try #require(r.childPID(), "the fake started a background child that also ignores SIGTERM")
            #expect(kill(child, 0) != 0, "the child was killed too, not left running")
            let worktree = r.fx.project.worktreesDirectory.appendingPathComponent(r.id)
            #expect(OrphanSweeper.orphans(inside: worktree).isEmpty, "no process of the turn is left")
            #expect(try await refusesConnections(try r.forwarderPort()), "and the forwarder is stopped")
        }

        @Test func aMissingOrShortKeyIsRefusedBeforeAWorktreeOrATurnExists() async throws {
            let r = try await opencodeRun()
            defer { r.gateway.stop() }
            let missing = await #expect(throws: RunnerError.self) {
                _ = try await r.run { $0.parentEnvironment["LITELLM_API_KEY"] = nil }
            }
            #expect("\(missing!)".contains("$LITELLM_API_KEY"), "\(missing!)")
            let short = await #expect(throws: RunnerError.self) {
                _ = try await r.run { $0.parentEnvironment["LITELLM_API_KEY"] = "short" }
            }
            #expect("\(short!)".contains("shorter than 8"), "\(short!)")
            #expect(!r.hasWorktree && r.events.allSatisfy { $0.kind != .turnStarted }, "nothing was started")
        }

        @Test func aBudgetGoalIsNotApprovedAndNotRunOnOpencode() async throws {
            let r = try await opencodeRun(
                goalEdit: { $0.replacingOccurrences(of: "spend_policy: timeout_only", with: "budget_usd: 1") }, approve: false)
            defer { r.gateway.stop() }
            let error = await #expect(throws: ThreadServiceError.self) { try await r.fx.service.approve(id: r.id) }
            #expect(error == .budgetNeedsCap(provider: "opencode"))
            #expect("\(error!)".contains("opencode cannot enforce a dollar limit"))
        }

        @Test func aBudgetFlagIsRefusedBecauseOpencodeHasNoCapToOverride() async throws {
            let r = try await opencodeRun()
            defer { r.gateway.stop() }
            let error = await #expect(throws: RunnerError.self) { _ = try await r.run { $0.budgetOverride = 1 } }
            #expect("\(error!)".contains("no dollar cap"), "a timeout-only goal has nothing to override: \(error!)")
            #expect(r.gateway.requests.isEmpty)
        }

        @Test func aMissingOpencodeIsRefusedByNameBeforeAnythingStarts() async throws {
            let r = try await opencodeRun()
            defer { r.gateway.stop() }
            var config = try String(contentsOf: r.fx.project.configURL, encoding: .utf8)
            config = config.replacingOccurrences(of: r.dir.appendingPathComponent("opencode").path, with: "/nonexistent/opencode")
            try config.write(to: r.fx.project.configURL, atomically: true, encoding: .utf8)
            let error = await #expect(throws: RunnerError.self) { _ = try await r.run() }
            #expect(error == .agentNotFound(provider: "opencode", name: "/nonexistent/opencode"), "\(error!)")
            #expect(!r.hasWorktree)
        }
    }

    private let soakEnabled = ProcessInfo.processInfo.environment["WORKBENCH_SOAK"] == "1"
    private let soakRuns = Int(ProcessInfo.processInfo.environment["WORKBENCH_OPENCODE_SOAK_RUNS"] ?? "") ?? 40

    /// The ways an OpenCode turn is ended from outside, or leaves something behind (P28 task 4).
    @Suite(.processGate) struct RunOpencodeRecoveryTests {
        /// The real CLI as its own process running a hanging turn, watched by a runner that never tracks its descendants: it is there
        /// to start and watch it, not to clean up after it. Returns once the fake has said which child it left running.
        private func hangingCLI(_ r: OpencodeRun) async throws -> (cli: ProcessRun, child: Int32) {
            try r.put("hang")
            var spawn = SpawnRequest(
                executable: WorkbenchBinary.executable, arguments: ["run"],
                environment: [
                    "PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "USER": NSUserName(), "LITELLM_API_KEY": gatewayKey,
                ],
                workingDirectory: r.fx.repo, timeout: 120)
            spawn.killGrace = 30
            spawn.snapshotInterval = 3600
            let cli = try ProcessRunner.start(spawn)
            #expect(await pollUntil { r.childPID() != nil }, "the fake never reached its hang")
            return (cli, try #require(r.childPID()))
        }

        private func results(_ r: OpencodeRun) -> [String?] { r.ended().map { $0.data["result"]?.stringValue } }

        @Test func aKilledRunnerLeavesAnOpenTurnThatTheNextRunClosesAndSweeps() async throws {
            let r = try await opencodeRun()
            defer { r.gateway.stop() }
            let (cli, child) = try await hangingCLI(r)
            defer { kill(child, SIGKILL) }
            let port = try r.forwarderPort()
            kill(cli.pid, SIGKILL)
            for await event in cli.events { if case .exited = event { break } }
            #expect(try r.fx.contents(r.id).openTurn == 1, "the turn is left open in the log")
            #expect(FakeClaude.alive(child), "a tool child outlives its SIGKILLed runner")
            #expect(Client.dial(port) == nil, "the forwarder lived in the runner, so it is gone with it")

            try FileManager.default.removeItem(at: r.dir.appendingPathComponent("hang"))
            let report = try await r.run()
            #expect(report.result == .succeeded, "\(report.result)")
            #expect(results(r) == ["interrupted", "succeeded"], "\(results(r))")
            #expect(try r.fx.contents(r.id).isHealthy)
            #expect(await FakeClaude.waitUntilGone(child), "what the dead runner left behind is swept")
        }

        @Test func aStopFromAnotherProcessEndsTheTurnAsStoppedAndLeavesNothing() async throws {
            let r = try await opencodeRun()
            defer { r.gateway.stop() }
            let (cli, child) = try await hangingCLI(r)
            defer { kill(child, SIGKILL) }
            let port = try r.forwarderPort()
            #expect(r.fx.service.requestStop(id: r.id) == .signalled(pid: cli.pid))
            var exit: ProcessExit?
            for await event in cli.events { if case .exited(let e) = event { exit = e } }
            #expect(exit?.termination == .exited(3), "`run` exits 3 when stopped: \(String(describing: exit))")
            #expect(results(r) == ["stopped"], "\(results(r))")
            #expect(try r.fx.contents(r.id).isHealthy)
            #expect(await FakeClaude.waitUntilGone(child), "the tool child went with the turn")
            #expect(Client.dial(port) == nil)
        }

        @Test func aStopBeforeTheProcessStartsRecordsAStoppedTurnAndStartsNothing() async throws {
            let r = try await opencodeRun()
            defer { r.gateway.stop() }
            let runner = r.fx.runner(r.id)
            await runner.stop()
            let report = try await runner.run(r.options())
            #expect(report.result == .stopped, "\(report.result)")
            #expect(results(r) == ["stopped"])
            #expect(r.events.filter { $0.kind == .turnStarted }.count == 1, "and it was started on the record")
            #expect(r.fx.transcript(r.id).isEmpty, "no process ran")
            #expect(Client.dial(try r.forwarderPort()) == nil, "the forwarder made for it is stopped")
        }

        @Test func aChildLeftBehindByASuccessfulTurnIsGoneWhenTheTurnIs() async throws {
            let r = try await opencodeRun()
            defer { r.gateway.stop() }
            try r.put("leftover")
            let report = try await r.run()
            #expect(report.result == .succeeded, "\(report.result)")
            let child = try #require(r.childPID(), "the fake left a child in a process group of its own")
            defer { kill(child, SIGKILL) }
            #expect(await FakeClaude.waitUntilGone(child), "it outlived the turn")
        }

        @Test func aGatewayErrorEventFailsTheTurnAndItsMessageIsKept() async throws {
            let r = try await opencodeRun()
            defer { r.gateway.stop() }
            try r.put("error")
            let report = try await r.run()
            #expect(report.result == .failed, "the event fails it: the fake exits 0 (\(report.result))")
            #expect(r.ended().count == 1)
            #expect(r.ended().first?.data["exit_code"] == .int(0))
            let errors = r.fx.transcript(r.id).filter { $0["type"]?.stringValue == "error" }
            #expect(errors.first?["error"]?["message"]?.stringValue == "Service Unavailable", "\(errors)")
            #expect(Client.dial(try r.forwarderPort()) == nil)
        }
    }

    /// Many OpenCode turns in one process, the way the app holds the runner: a forwarder that kept a socket or a thread would show as
    /// descriptors that grow. Off by default, like the other soaks: `WORKBENCH_SOAK=1 swift test --filter OpencodeSoakTests`.
    @Suite(.serialized, .processGate, .enabled(if: soakEnabled)) struct OpencodeSoakTests {
        @Test func manyTurnsEndOnceEachAndNothingAccumulates() async throws {
            await SoakExclusion.shared.acquire()
            defer { Task { await SoakExclusion.shared.release() } }
            let modes = ["", "crash", "error", "hang", "ignoreterm", "leftover"]
            let before = openDescriptorCount()
            var results: [String: Int] = [:]
            for i in 0..<soakRuns {
                let mode = modes[i % modes.count]
                let r = try await opencodeRun()
                defer { r.gateway.stop() }
                if !mode.isEmpty { try r.put(mode) }
                let hangs = mode == "hang" || mode == "ignoreterm"
                let report = try await r.run(timeout: hangs ? 5 : 30) { $0.killGrace = 1 }
                results[report.result.rawValue, default: 0] += 1
                let label = "\(mode.isEmpty ? "ok" : mode) #\(i)"
                let expected: RunResult = hangs ? .timedOut : (mode == "crash" || mode == "error" ? .failed : .succeeded)
                #expect(report.result == expected, "\(label): \(report.result)")
                let contents = try r.fx.contents(r.id)
                #expect(contents.isHealthy && contents.openTurn == nil, "\(label): \(contents.problems)")
                #expect(r.ended().count == 1, "\(label): one turn.ended")
                #expect(Client.dial(try r.forwarderPort()) == nil, "\(label): the forwarder is still listening")
                // A mode that ran out its time before the fake got to it proves nothing, so each must have left its mark.
                if hangs || mode == "leftover" {
                    let child = try #require(r.childPID(), "\(label): the fake never started its child")
                    #expect(await FakeClaude.waitUntilGone(child), "\(label): a child is left")
                }
                if mode == "ignoreterm" {
                    #expect(r.ended().first?.data["escalated_to_kill"] == .bool(true), "\(label): SIGTERM was never ignored")
                }
                try await r.fx.service.abandon(id: r.id, force: true)
            }
            let after = openDescriptorCount()
            #expect(after - before <= 4, "descriptors grew from \(before) to \(after) over \(soakRuns) turns")
            print("SOAK opencode runs=\(soakRuns) results=\(results.sorted { $0.key < $1.key }) fds \(before)->\(after)")
        }
    }
#endif
