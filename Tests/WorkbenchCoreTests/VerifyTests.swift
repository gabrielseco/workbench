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
        #expect(png.data["sha256"]?.stringValue == "8dccea5217902053b636f0e105c590eb30db4280b8a7a51806110f7ff7b5177e")

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

    @Test func theStepRecordsTheCommitAndTreeItRanAtOnStartAndOnEveryProofFile() async throws {
        let script = try CheckScript()
        let body = "printf a > \"$WORKBENCH_PROOF_DIR/a.png\"\nprintf b > \"$WORKBENCH_PROOF_DIR/b.png\""
        let fx = try await verifyFixture(script, body: body)
        let id = try await fx.approvedThread()
        // The turn's own change is in the tree verify saw, committed or not.
        _ = try await fx.runner(id).run(fx.options("write=a.txt"))
        let worktree = fx.project.worktreesDirectory.appendingPathComponent(id)
        let now = try #require(await ProofIdentity.of(worktree: worktree, git: fx.git, attributesFrom: nil))
        let started = try #require(try fx.events(id).first { $0.kind == .verifyStarted })
        #expect(started.data["commit"]?.stringValue == now.commit)
        #expect(started.data["tree"]?.stringValue == now.tree)
        let proof = try fx.proofEvents(id)
        #expect(proof.count == 2)
        for event in proof {
            #expect(event.data["commit"]?.stringValue == now.commit)
            #expect(event.data["tree"]?.stringValue == now.tree)
        }
        let verify = try #require(ThreadStore(project: fx.project).state(of: id).review.verify)
        #expect(verify.tree == now.tree)
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

    @Test func aServerAToolDetachedIsSweptBecauseItsWorkingDirectoryIsTheWorktree() async throws {
        // `verify-ui` starts its server in a new session and exits, so it is no descendant of the step. A double
        // fork gets it re-parented to launchd within a moment; the step then idles for several snapshots of the
        // process tree, none of which can see it. (If a snapshot caught it in that first moment, the runner's own
        // tree sweep kills it instead, so either counter proves the server did not outlive the step.)
        let script = try CheckScript()
        let body = """
            /usr/bin/python3 -c '
            import os, sys
            if os.fork() == 0:
                os.setsid()
                if os.fork() == 0:
                    open("\(script.path("server"))", "w").write(str(os.getpid()))
                    os.execvp("sleep", ["sleep", "300"])
                os._exit(0)
            '
            sleep 1
            exit 0
            """
        let fx = try await verifyFixture(script, body: body)
        let id = try await fx.approvedThread()
        let report = try await fx.runner(id).run(fx.options())
        #expect(report.verify?.result == .passed)
        let server = try script.pid("server")
        defer { kill(server, SIGKILL) }
        #expect(await FakeClaude.waitUntilGone(server), "a detached server does not outlive the verify step")
        let ended = try #require(try fx.verifyEnds(id).first)
        let swept = (ended.data["swept_orphans"]?.intValue ?? 0) + (ended.data["swept_processes"]?.intValue ?? 0)
        #expect(swept >= 1, "the cleanup is recorded")
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

    @Test func aVerifyLeftOpenByADeadRunnerIsClosedByTheNextRunBeforeItsFirstTurn() async throws {
        let script = try CheckScript()
        let fx = try await verifyFixture(script, body: "printf x > \"$WORKBENCH_PROOF_DIR/a.png\"")
        let id = try await fx.approvedThread()
        do {
            let log = try EventLogWriter.open(at: fx.project.eventsURL(id))
            try await log.append(.turnStarted, turn: 1, data: ["session_id": "x", "resume": false])
            try await log.append(.turnEnded, turn: 1, data: ["result": "succeeded"])
            try await log.append(.verifyStarted, turn: 1, data: ["command": "x"])
            await log.close()  // the runner "dies" during the verify step
        }
        #expect(try fx.contents(id).openVerify == 1)

        let report = try await fx.runner(id).run(fx.options(feedback: "again"))
        #expect(report.verify?.result == .passed)
        let kinds = try fx.kinds(id)
        let recovered = try #require(try fx.events(id).first { $0.kind == .verifyEnded })
        #expect(recovered.data["result"]?.stringValue == "interrupted")
        #expect(recovered.data["synthetic"] == true)
        #expect(try #require(kinds.firstIndex(of: "verify.ended")) < (try #require(kinds.lastIndex(of: "turn.started"))))
        #expect(try fx.contents(id).openVerify == nil)
        #expect(try fx.contents(id).isHealthy)
    }

    @Test func aSuccessfulVerifyThatWritesNothingHasAnEmptyProofList() async throws {
        let script = try CheckScript()
        let fx = try await verifyFixture(script, body: "echo nothing to show")
        let id = try await fx.approvedThread()
        let report = try await fx.runner(id).run(fx.options())
        #expect(report.verify?.result == .passed)
        #expect(report.verify?.proof.isEmpty == true)
        #expect(try fx.verifyEnds(id).first?.data["proof_files"]?.intValue == 0)
    }

    @Test func aStopBeforeTheVerifyStartsMeansItDoesNotRun() async throws {
        let script = try CheckScript()
        let fx = try await verifyFixture(script, body: "touch \(script.path("ran"))")
        let id = try await fx.approvedThread()
        let runner = fx.runner(id)
        async let report = runner.run(fx.options("hang-after=2", timeout: 30))
        try await Task.sleep(nanoseconds: 1_500_000_000)
        await runner.stop()
        let result = try await report
        #expect(result.result == .stopped)
        #expect(result.verify == nil)
        #expect(!script.exists("ran"))
    }

    @Test func aVerifyThatIgnoresSIGTERMIsKilledWithItsChildren() async throws {
        let script = try CheckScript()
        let body = """
            trap '' TERM
            sleep 300 &
            echo $! > \(script.path("child"))
            while :; do sleep 1; done
            """
        let fx = try await verifyFixture(script, body: body)
        let id = try await fx.approvedThread()
        var options = fx.options(grace: 1)
        options.verifyTimeoutOverride = 3
        let report = try await fx.runner(id).run(options)
        #expect(report.verify?.result == .timedOut)
        let child = try script.pid("child")
        defer { kill(child, SIGKILL) }
        #expect(await FakeClaude.waitUntilGone(child))
        #expect(try fx.verifyEnds(id).first?.data["escalated_to_kill"] == true)
    }

    @Test func collectingProofIsBoundedInEntriesFileSizeAndTotalBytes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wb-proof-\(UUID().uuidString)")
        let thread = dir.appendingPathComponent("thread")
        let proof = thread.appendingPathComponent("proof/turn-1")
        try FileManager.default.createDirectory(at: proof, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for (name, size) in [("a.png", 10), ("b.png", 10), ("big.png", 100), ("c.png", 10)] {
            try Data(repeating: 1, count: size).write(to: proof.appendingPathComponent(name))
        }

        let all = VerifyRunner.collect(proofDirectory: proof, threadDirectory: thread)
        #expect(all.files.map(\.name) == ["a.png", "b.png", "big.png", "c.png"])
        #expect(all.files.first?.path == "proof/turn-1/a.png")

        let bigSkipped = VerifyRunner.collect(proofDirectory: proof, threadDirectory: thread, maxFileBytes: 50)
        #expect(bigSkipped.files.map(\.name) == ["a.png", "b.png", "c.png"])
        #expect(bigSkipped.omitted == 1)

        let totalCapped = VerifyRunner.collect(
            proofDirectory: proof, threadDirectory: thread, maxFileBytes: 50, maxTotalBytes: 20)
        #expect(totalCapped.files.map(\.name) == ["a.png", "b.png"])
        #expect(totalCapped.omitted == 2)

        let fewEntries = VerifyRunner.collect(proofDirectory: proof, threadDirectory: thread, maxEntries: 2)
        #expect(fewEntries.files.count <= 2)
        #expect(fewEntries.omitted >= 1)

        let many = proof.deletingLastPathComponent().appendingPathComponent("many")
        try FileManager.default.createDirectory(at: many, withIntermediateDirectories: true)
        for i in 0..<40 { try Data([1]).write(to: many.appendingPathComponent("f\(i).png")) }
        let capped = VerifyRunner.collect(proofDirectory: many, threadDirectory: thread, maxEntries: 10)
        #expect(capped.files.count <= 10, "the walk stops at the entry limit")
        #expect(capped.omitted >= 1)

        let noTime = VerifyRunner.collect(proofDirectory: proof, threadDirectory: thread, budget: -1)
        #expect(noTime.files.isEmpty)
        #expect(noTime.omitted >= 1)
    }
}

@Suite struct LogFollowTests {
    private func event(_ kind: EventKind, _ result: String? = nil) -> Event {
        Event(seq: 1, ts: "t", turn: 1, kind: kind, data: result.map { ["result": .string($0)] } ?? [:])
    }

    private func ends(
        _ kind: EventKind, _ result: String? = nil, checks: Bool = false, verifies: Bool = false,
        succeeded: Bool = true
    ) -> Bool {
        LogFormatter.followEnds(
            event(kind, result), sawStart: true, checks: checks, verifies: verifies, turnSucceeded: succeeded)
    }

    @Test func followingWaitsForTheVerifyStepOfASuccessfulTurn() {
        #expect(!ends(.turnEnded, "succeeded", checks: true, verifies: true))
        #expect(!ends(.checkRan, "passed", checks: true, verifies: true))
        #expect(ends(.verifyEnded, "passed", checks: true, verifies: true))
        #expect(!ends(.turnEnded, "succeeded", verifies: true), "no check: the verify step still follows the turn")
    }

    @Test func aTurnThatDidNotSucceedOrWasStoppedEndsAtItsCheckOrItself() {
        #expect(ends(.checkRan, "failed", checks: true, verifies: true, succeeded: false))
        #expect(ends(.checkRan, "stopped", checks: true, verifies: true))
        #expect(ends(.turnEnded, "stopped", verifies: true, succeeded: false))
    }

    @Test func joiningAtAnOpenCheckKnowsTheTurnSucceeded() {
        func turnEnded(_ result: String) -> Event { event(.turnEnded, result) }
        #expect(LogFormatter.latestTurnSucceeded([turnEnded("failed"), turnEnded("succeeded")]))
        #expect(!LogFormatter.latestTurnSucceeded([turnEnded("succeeded"), turnEnded("failed")]))
        #expect(!LogFormatter.latestTurnSucceeded([]))
    }

    @Test func withoutAVerifyStepNothingChanges() {
        #expect(ends(.turnEnded, "succeeded"))
        #expect(!ends(.turnEnded, "succeeded", checks: true))
        #expect(ends(.checkRan, "passed", checks: true))
    }
}

@Suite struct VerifyPromptTests {
    private func goal(_ proof: String) throws -> Goal {
        let text = """
            ---
            id: g-1
            title: T
            base: main
            budget_usd: 1
            turn_timeout_min: 5
            ---

            ## Request

            Do it.

            ## Criteria

            - [c1] It shows.
              - proof: \(proof)

            ## Out of scope

            - Nothing.
            """
        return try GoalFile.parse(text).goal
    }

    @Test func claudeIsToldWhichCriteriaTheVerifyStepCovers() throws {
        let prompt = PromptBuilder.firstPrompt(
            goal: try goal("screenshot: home"), checkCommand: nil, verifies: true)
        #expect(prompt.contains("## Verification"))
        #expect(prompt.contains("`screenshot: <name>`"))
        #expect(prompt.contains("do not need to take"))
    }

    @Test func nothingIsAddedWithoutAVerifyStepOrAScreenshotCriterion() throws {
        let shot = try goal("screenshot: home")
        #expect(!PromptBuilder.firstPrompt(goal: shot, checkCommand: nil, verifies: false).contains("Verification"))
        let other = try goal("`swift test` passes")
        #expect(!PromptBuilder.firstPrompt(goal: other, checkCommand: nil, verifies: true).contains("Verification"))
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
