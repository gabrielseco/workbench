import Foundation
import Testing

@testable import WorkbenchCore

private func verifyFixture(_ script: CheckScript, body: String, extra: String = "") async throws -> RunnerFixture {
    let path = try script.write(body, name: "verify.sh")
    return try await RunnerFixture(extraConfig: "verify_command = \"\(path)\"\n\(extra)")
}

extension RunnerFixture {
    func verifyEnds(_ id: String) throws -> [Event] { try events(id).filter { $0.kind == .verifyEnded } }
    func proofEvents(_ id: String) throws -> [Event] { try events(id).filter { $0.kind == .proofAdded } }
    func verifyOutput(_ id: String, turn: Int = 1) throws -> String {
        try String(contentsOf: project.verifyOutputURL(id, turn: turn), encoding: .utf8)
    }
}

@Suite struct VerifyRunnerTests {
    @Test func aVerifyStepRecordsItsProofAfterTheCheck() async throws {
        let script = try CheckScript()
        let body = """
            echo "dir=$WORKBENCH_PROOF_DIR"
            echo "thread=$WORKBENCH_THREAD"
            echo "goal=$WORKBENCH_GOAL"
            echo "port=$WORKBENCH_PORT"
            printf shot > "$WORKBENCH_PROOF_DIR/home.png"
            mkdir "$WORKBENCH_PROOF_DIR/flows"
            printf '{}' > "$WORKBENCH_PROOF_DIR/flows/verdict.json"
            """
        let path = try script.write(body, name: "verify.sh")
        let check = try script.write("echo ok", name: "check.sh")
        let fx = try await RunnerFixture(
            extraConfig: "verify_command = \"\(path)\"\ncheck_command = \"\(check)\"")
        let id = try await fx.approvedThread()
        let notices = NoticeBox()
        let report = try await fx.runner(id, notices: notices).run(fx.options())

        #expect(report.result == .succeeded)
        #expect(report.verify?.result == .passed)
        #expect(
            try fx.kinds(id).suffix(7)
                == ["turn.ended", "check.started", "check.ran", "verify.started", "proof.added", "proof.added", "verify.ended"])

        let started = try #require(try fx.events(id).first { $0.kind == .verifyStarted })
        #expect(started.data["command"]?.stringValue == path)
        #expect(started.data["proof_ref"]?.stringValue == "proof/turn-1")
        let port = try #require(started.data["port"]?.intValue)
        #expect(port > 0)

        let proof = try fx.proofEvents(id)
        #expect(proof.compactMap { $0.data["name"]?.stringValue } == ["flows/verdict.json", "home.png"])
        let png = try #require(proof.first { $0.data["name"]?.stringValue == "home.png" })
        #expect(png.data["path"]?.stringValue == "proof/turn-1/home.png")
        #expect(png.data["bytes"]?.intValue == 4)
        // sha256 of "shot"
        #expect(png.data["sha256"]?.stringValue?.count == 64)

        let ended = try #require(try fx.verifyEnds(id).first)
        #expect(ended.data["result"]?.stringValue == "passed")
        #expect(ended.data["proof_files"]?.intValue == 2)
        #expect(ended.data["output_ref"]?.stringValue == "verify/turn-1.log")

        let directory = fx.project.proofDirectory(id, turn: 1)
        let output = try fx.verifyOutput(id)
        #expect(output.contains("dir=\(directory.resolvingSymlinksInPath().path)") || output.contains("dir=\(directory.path)"))
        #expect(output.contains("thread=\(id)"))
        #expect(output.contains("goal=\(fx.project.goalURL(id).path)"))
        #expect(output.contains("port=\(port)"))
        #expect(try fx.contents(id).isHealthy)
        #expect(try fx.contents(id).openVerify == nil)
        #expect(notices.all.contains { if case .verifyEnded(let v) = $0 { v.proof.count == 2 } else { false } })
    }

    @Test func aFailingVerifyIsRecordedAndKeepsWhatItWrote() async throws {
        let script = try CheckScript()
        let fx = try await verifyFixture(
            script, body: "printf partial > \"$WORKBENCH_PROOF_DIR/half.png\"\necho no browser >&2\nexit 7")
        let id = try await fx.approvedThread()
        let report = try await fx.runner(id).run(fx.options())

        #expect(report.result == .succeeded, "the turn's own result is not the verify step's")
        #expect(report.verify?.result == .failed)
        #expect(report.verify?.exitCode == 7)
        #expect(report.verify?.proof.map(\.name) == ["half.png"])
        #expect(try fx.verifyOutput(id) == "no browser\n")
    }

    @Test func noVerifyCommandMeansNothingRuns() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        let report = try await fx.runner(id).run(fx.options())
        #expect(report.verify == nil)
        #expect(try fx.kinds(id).filter { $0.hasPrefix("verify.") || $0 == "proof.added" }.isEmpty)
    }

    @Test func aTurnThatDidNotSucceedIsNotVerified() async throws {
        let script = try CheckScript()
        let fx = try await verifyFixture(script, body: "touch \(script.path("ran"))")
        let id = try await fx.approvedThread()
        var options = fx.options()
        options.parentEnvironment["FAKE_CLAUDE"] = "crash-after=1"
        let report = try await fx.runner(id).run(options)
        #expect(report.result == .failed)
        #expect(report.verify == nil)
        #expect(!script.exists("ran"))
    }

    @Test func aVerifyOverTheTimeoutIsKilledWithTheDevServerItStarted() async throws {
        let script = try CheckScript()
        let body = """
            sleep 300 &
            echo $! > \(script.path("server"))
            echo started
            wait
            """
        let fx = try await verifyFixture(script, body: body)
        let id = try await fx.approvedThread()
        var options = fx.options(grace: 2)
        options.verifyTimeoutOverride = 4
        let report = try await fx.runner(id).run(options)

        #expect(report.verify?.result == .timedOut)
        let ended = try #require(try fx.verifyEnds(id).first)
        #expect(ended.data["result"]?.stringValue == "timed_out")
        let server = try script.pid("server")
        defer { kill(server, SIGKILL) }
        #expect(await FakeClaude.waitUntilGone(server), "the dev server went with the verify step")
        #expect(try fx.contents(id).isHealthy)
    }

    @Test func aLeftOverDevServerIsSweptWhenTheVerifyStepExits() async throws {
        let script = try CheckScript()
        let body = """
            sleep 300 >/dev/null 2>&1 &
            echo $! > \(script.path("server"))
            exit 0
            """
        let fx = try await verifyFixture(script, body: body)
        let id = try await fx.approvedThread()
        let report = try await fx.runner(id).run(fx.options())
        #expect(report.verify?.result == .passed)
        let server = try script.pid("server")
        defer { kill(server, SIGKILL) }
        #expect(await FakeClaude.waitUntilGone(server), "nothing the verify step started outlives it")
    }

    @Test func aSymlinkInTheProofDirectoryIsNotRecorded() async throws {
        let script = try CheckScript()
        let secret = script.path("secret.txt")
        try "secret".write(toFile: secret, atomically: true, encoding: .utf8)
        let fx = try await verifyFixture(
            script, body: "ln -s \(secret) \"$WORKBENCH_PROOF_DIR/leak.png\"\nprintf ok > \"$WORKBENCH_PROOF_DIR/a.png\"")
        let id = try await fx.approvedThread()
        _ = try await fx.runner(id).run(fx.options())
        #expect(try fx.proofEvents(id).compactMap { $0.data["name"]?.stringValue } == ["a.png"])
    }

    @Test func aMissingVerifyExecutableIsRecordedAsFailedNotMet() async throws {
        let fx = try await RunnerFixture(extraConfig: "verify_command = \"scripts/does-not-exist.sh\"")
        let id = try await fx.approvedThread()
        let report = try await fx.runner(id).run(fx.options())
        #expect(report.verify?.result == .failed)
        #expect(report.verify?.proof.isEmpty == true)
        #expect(try fx.verifyOutput(id).contains("cannot find"))
    }

    @Test func eachTurnGetsItsOwnEmptyProofDirectory() async throws {
        let script = try CheckScript()
        let body = """
            ls "$WORKBENCH_PROOF_DIR" | wc -l | tr -d ' ' >> \(script.path("counts"))
            printf x > "$WORKBENCH_PROOF_DIR/a.png"
            """
        let fx = try await verifyFixture(script, body: body)
        let id = try await fx.approvedThread()
        _ = try await fx.runner(id).run(fx.options())
        _ = try await fx.runner(id).run(fx.options(feedback: "again"))
        #expect(try String(contentsOfFile: script.path("counts"), encoding: .utf8) == "0\n0\n")
        #expect(FileManager.default.fileExists(atPath: fx.project.proofDirectory(id, turn: 2).path))
    }

    @Test func aVerifyLeftOpenByADeadRunnerIsClosedOnTheNextRun() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        let log = try EventLogWriter.open(at: fx.project.eventsURL(id))
        try await log.append(.verifyStarted, turn: 1, data: ["command": "x"])
        await log.close()
        #expect(try fx.contents(id).openVerify == 1)

        let reopened = try EventLogWriter.open(at: fx.project.eventsURL(id))
        _ = try await reopened.recoverOrphanedVerify()
        await reopened.close()
        let last = try #require(try fx.events(id).last)
        #expect(last.kind == .verifyEnded)
        #expect(last.data["result"]?.stringValue == "interrupted")
        #expect(try fx.contents(id).openVerify == nil)
    }
}

@Suite struct VerifyConfigTests {
    @Test func verifyKeysAreParsedAndValidated() throws {
        let toml = """
            verify_command = "scripts/verify.sh"
            verify_timeout_min = 20

            [tools]
            available = ["Read"]
            """
        let config = try Config.parse(toml)
        #expect(config.verifyCommand == "scripts/verify.sh")
        #expect(config.verifyTimeoutMin == 20)
        #expect(try Config.parse("[tools]\navailable = [\"Read\"]\n").verifyTimeoutMin == 10)
        #expect(throws: ConfigError.self) {
            try Config.parse("verify_command = \"a && b\"\n[tools]\navailable = [\"Read\"]\n")
        }
        #expect(throws: ConfigError.self) {
            try Config.parse("verify_timeout_min = 0\n[tools]\navailable = [\"Read\"]\n")
        }
    }

    @Test func theVerifyCommandIsNeverOfferedToClaude() throws {
        let config = try Config.parse(
            "verify_command = \"scripts/verify.sh\"\n[tools]\navailable = [\"Bash\"]\n")
        #expect(!config.effectiveAllowedTools.contains { $0.contains("verify") })
    }
}
