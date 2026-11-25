import Foundation
import Testing

@testable import WorkbenchCore

#if os(macOS)
    private let gatewayKey = "test-gateway-key-0123456789"

    // swiftlint:disable line_length
    /// An `opencode` that runs where a real one would, under `sandbox-exec` and behind the forwarder, and says what it saw in the
    /// event stream (which the runner records verbatim): the key variable's value, the status of a request through the forwarder,
    /// whether it could write outside its worktree, and its config's address. It edits `a.txt` in the worktree it starts in.
    /// `hang` and `crash` in its folder change what it does.
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
#endif
