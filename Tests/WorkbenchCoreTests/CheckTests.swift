import Foundation
import Testing

@testable import WorkbenchCore

// MARK: helpers

/// A scratch directory outside the repository, holding a check script and whatever it leaves behind.
struct CheckScript {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wb-check-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func path(_ name: String) -> String { directory.appendingPathComponent(name).path }

    /// Writes an executable `/bin/sh` script and returns its path.
    @discardableResult
    func write(_ body: String, name: String = "check.sh", in other: URL? = nil) throws -> String {
        let url = (other ?? directory).appendingPathComponent(name)
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    func pid(_ name: String) throws -> pid_t {
        let text = try String(contentsOfFile: path(name), encoding: .utf8)
        return try #require(pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: path(name)) }

    /// Generous: CI runs the suites in parallel and a spawn can wait seconds; a pass returns at once.
    func waitFor(_ name: String, timeout: TimeInterval = 60) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if exists(name) { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return exists(name)
    }
}

extension RunnerFixture {
    /// A fixture whose config names `command` as the check.
    static func checking(_ command: String) async throws -> RunnerFixture {
        try await RunnerFixture(extraConfig: "check_command = \"\(command)\"")
    }

    func checkStarts(_ id: String) throws -> [Event] { try events(id).filter { $0.kind == .checkStarted } }

    func checkRuns(_ id: String) throws -> [Event] { try events(id).filter { $0.kind == .checkRan } }

    func checkOutput(_ id: String, turn: Int = 1) throws -> String {
        try String(contentsOf: project.checkOutputURL(id, turn: turn), encoding: .utf8)
    }
}

private let truncationMarker = "[output truncated at 1048576 bytes]\n"

// MARK: a check, run and recorded

@Suite(.processGate) struct CheckRunnerTests {
    @Test func aPassingCheckIsRecordedWithItsOutputInOrder() async throws {
        let script = try CheckScript()
        let fx = try await RunnerFixture.checking(
            try script.write("echo out-1\necho err-1 >&2\necho out-2\necho err-2 >&2"))
        let id = try await fx.approvedThread()
        let notices = NoticeBox()
        let report = try await fx.runner(id, notices: notices).run(fx.options())

        #expect(report.result == .succeeded)
        #expect(report.check?.result == .passed)
        #expect(try fx.kinds(id).suffix(3) == ["turn.ended", "check.started", "check.ran"])

        let started = try #require(try fx.checkStarts(id).first)
        #expect(started.turn == 1)
        #expect(started.data["command"]?.stringValue == script.path("check.sh"))

        let ran = try #require(try fx.checkRuns(id).first)
        #expect(ran.turn == 1)
        #expect(ran.data["command"]?.stringValue == script.path("check.sh"))
        #expect(ran.data["result"]?.stringValue == "passed")
        #expect(ran.data["exit_code"]?.intValue == 0)
        #expect(ran.data["signal"] == .null)
        #expect((ran.data["duration_ms"]?.intValue ?? -1) >= 0)
        #expect(ran.data["output_ref"]?.stringValue == "checks/turn-1.log")
        #expect(ran.data["output_truncated"] == false)

        #expect(try fx.checkOutput(id) == "out-1\nerr-1\nout-2\nerr-2\n")
        #expect(try fx.contents(id).isHealthy)
        #expect(try fx.contents(id).openCheck == nil)
        #expect(notices.all.contains { if case .checkStarted(1, _) = $0 { true } else { false } })
        #expect(notices.all.contains { if case .checkRan(let c) = $0 { c.result == .passed } else { false } })
    }

    @Test func aFailingCheckKeepsItsExitCodeAndOutput() async throws {
        let script = try CheckScript()
        let fx = try await RunnerFixture.checking(try script.write("echo two tests failed\necho boom >&2\nexit 3"))
        let id = try await fx.approvedThread()
        let report = try await fx.runner(id).run(fx.options())

        #expect(report.result == .succeeded, "the turn's own result is not the check's")
        #expect(report.check?.result == .failed)
        #expect(report.check?.exitCode == 3)
        let ran = try #require(try fx.checkRuns(id).first)
        #expect(ran.data["result"]?.stringValue == "failed")
        #expect(ran.data["exit_code"]?.intValue == 3)
        #expect(try fx.checkOutput(id) == "two tests failed\nboom\n")
    }

    @Test func theCheckRunsInTheWorktreeWithArgumentsAndTheMinimalEnvironment() async throws {
        let script = try CheckScript()
        let body = """
            pwd -P
            echo "args=$*"
            echo "token=${GITHUB_TOKEN:-none} agent=${SSH_AUTH_SOCK:-none} home=${HOME:+set}"
            if read line; then echo "stdin=open"; else echo "stdin=eof"; fi
            """
        let fx = try await RunnerFixture.checking("\(try script.write(body))  --fast\tunit")
        let id = try await fx.approvedThread()
        _ = try await fx.runner(id).run(fx.options())

        let worktree = OrphanSweeper.realPath(fx.project.worktreesDirectory.appendingPathComponent(id))
        #expect(
            try fx.checkOutput(id)
                == "\(worktree)\nargs=--fast unit\ntoken=none agent=none home=set\nstdin=eof\n")
    }

    // MARK: where the command comes from

    @Test func withNoCheckCommandNothingRuns() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        let report = try await fx.runner(id).run(fx.options())

        #expect(report.result == .succeeded)
        #expect(report.check == nil)
        #expect(try fx.kinds(id).filter { $0.hasPrefix("check.") }.isEmpty)
        let checks = fx.project.threadDirectory(id).appendingPathComponent("checks").path
        #expect(!FileManager.default.fileExists(atPath: checks))
    }

    @Test func aDecoyInTheWorktreeDoesNotReplaceTheConfiguredCommand() async throws {
        let script = try CheckScript()
        let name = "wbcheck-\(UUID().uuidString.prefix(8).lowercased())"
        try script.write("echo real", name: name)

        let fx = try await RunnerFixture.checking(name)
        // The worktree gets a file of the same name, and a config of its own naming another command.
        try script.write("echo decoy\nexit 1", name: name, in: fx.repo)
        try script.write("echo decoy\nexit 1", name: "decoy.sh", in: fx.repo)
        let inner = fx.repo.appendingPathComponent("nested/.workbench")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try "check_command = \"./decoy.sh\"\n".write(
            to: inner.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        _ = try await fx.git.run(["add", name, "decoy.sh", "nested"], in: fx.repo)
        _ = try await fx.git.run(["commit", "-q", "-m", "decoys"], in: fx.repo)

        let id = try await fx.approvedThread()
        var options = fx.options()
        // `.` and an empty entry come first: a shell would find the worktree's file before the real one.
        options.parentEnvironment["PATH"] = ".::\(script.directory.path):/usr/bin:/bin"
        let report = try await fx.runner(id).run(options)

        let worktree = fx.project.worktreesDirectory.appendingPathComponent(id)
        #expect(FileManager.default.isExecutableFile(atPath: worktree.appendingPathComponent(name).path))
        #expect(report.check?.result == .passed)
        #expect(report.check?.command == name)
        #expect(try fx.checkOutput(id) == "real\n")
    }

    @Test func aBareNameIsOnlyLookedUpInAbsolutePathEntries() throws {
        let script = try CheckScript()
        try script.write("echo real", name: "tool")
        let worktree = try CheckScript()
        try worktree.write("echo decoy", name: "tool")
        try FileManager.default.createDirectory(
            at: worktree.directory.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        try worktree.write("echo project", name: "scripts/check.sh")

        func resolve(_ name: String, _ path: String) -> String? {
            CheckRunner.resolve(name, worktree: worktree.directory, searchPath: path)?.path
        }
        #expect(resolve("tool", ".::\(script.directory.path)") == script.path("tool"))
        #expect(resolve("tool", ".:") == nil, "the worktree is not searched for a bare name")
        #expect(resolve("scripts/check.sh", "") == worktree.path("scripts/check.sh"), "a path is the project's")
        #expect(resolve("scripts/missing.sh", "/usr/bin") == nil)
    }

    @Test func theCommandTextIsNeverReadByAShell() throws {
        let worktree = try CheckScript()
        let check = CheckRunner(
            command: "/bin/echo  one two", worktree: worktree.directory, environment: [:], timeout: 5, killGrace: 1)
        let request = try #require(check.request())
        #expect(request.executable.path == "/bin/sh")
        #expect(request.arguments == ["-c", #"exec "$@" 2>&1"#, "sh", "/bin/echo", "one", "two"])
        #expect(request.workingDirectory == worktree.directory)
    }

    @Test func aCommandThatCannotBeFoundIsAFailedCheckNotACrash() async throws {
        let fx = try await RunnerFixture.checking("no-such-check-\(UUID().uuidString.prefix(8).lowercased())")
        let id = try await fx.approvedThread()
        let report = try await fx.runner(id).run(fx.options())

        #expect(report.check?.result == .failed)
        #expect(report.check?.exitCode == nil)
        let ran = try fx.checkRuns(id)
        #expect(ran.count == 1)
        let failed = try #require(ran.first)
        #expect(failed.data["error"]?.stringValue?.contains("cannot find") == true)
        #expect(try fx.checkOutput(id).contains("cannot find"))
        #expect(try fx.contents(id).isHealthy)
    }

    // MARK: bounded

    @Test func aCheckOverTheTimeoutIsKilledWithItsChildren() async throws {
        let script = try CheckScript()
        let body = """
            sleep 300 &
            echo $! > \(script.path("child"))
            echo $$ > \(script.path("self"))
            echo waiting
            wait
            """
        let fx = try await RunnerFixture.checking(try script.write(body))
        let id = try await fx.approvedThread()
        var options = fx.options(grace: 2)
        options.checkTimeoutOverride = 4
        let report = try await fx.runner(id).run(options)

        #expect(report.result == .succeeded)
        #expect(report.check?.result == .timedOut)
        let ran = try #require(try fx.checkRuns(id).first)
        #expect(ran.data["result"]?.stringValue == "timed_out")
        #expect(try fx.checkRuns(id).count == 1)
        #expect(try fx.checkOutput(id) == "waiting\n")
        let child = try script.pid("child")
        defer { kill(child, SIGKILL) }
        #expect(await FakeClaude.waitUntilGone(child), "the check's child went with it")
        #expect(await FakeClaude.waitUntilGone(try script.pid("self")))
        #expect(try fx.contents(id).isHealthy)
    }

    @Test func aCheckThatIgnoresSIGTERMIsKilledWithItsChildren() async throws {
        let script = try CheckScript()
        let body = """
            trap '' TERM
            sleep 300 &
            echo $! > \(script.path("child"))
            echo $$ > \(script.path("self"))
            while :; do sleep 1; done
            """
        let fx = try await RunnerFixture.checking(try script.write(body))
        let id = try await fx.approvedThread()
        var options = fx.options(grace: 0.5)
        options.checkTimeoutOverride = 4
        let report = try await fx.runner(id).run(options)

        #expect(report.check?.result == .timedOut)
        #expect(report.check?.signal == SIGKILL)
        let ran = try #require(try fx.checkRuns(id).first)
        #expect(ran.data["result"]?.stringValue == "timed_out")
        #expect(ran.data["escalated_to_kill"] == true)
        let child = try script.pid("child")
        defer { kill(child, SIGKILL) }
        #expect(await FakeClaude.waitUntilGone(child), "a child that inherited the ignored SIGTERM is gone too")
        #expect(await FakeClaude.waitUntilGone(try script.pid("self")))
    }

    @Test func outputOverTheLimitIsTruncatedAndTheCommandIsNotBlocked() async throws {
        let script = try CheckScript()
        // About 4.6 MiB of lines, then proof that the script got to its end.
        let body = """
            line=$(printf '%0100d' 7)
            i=0
            while [ $i -lt 48000 ]; do echo "$line"; i=$((i + 1)); done
            echo late >&2
            touch \(script.path("finished"))
            """
        let fx = try await RunnerFixture.checking(try script.write(body))
        let id = try await fx.approvedThread()
        let report = try await fx.runner(id).run(fx.options(timeout: 60))

        #expect(report.check?.result == .passed, "it ran to the end: a full pipe never stopped it")
        #expect(script.exists("finished"))
        #expect(report.check?.outputTruncated == true)
        #expect(try #require(try fx.checkRuns(id).first).data["output_truncated"] == true)

        let data = try Data(contentsOf: fx.project.checkOutputURL(id, turn: 1))
        let kept = data.dropLast(truncationMarker.utf8.count)
        #expect(String(decoding: data.suffix(truncationMarker.utf8.count), as: UTF8.self) == truncationMarker)
        // The cut fell inside a line, so one newline separates it from the marker.
        #expect(kept.count == 1_048_576 + 1)
        #expect(kept.last == 0x0A)
        #expect(!String(decoding: data, as: UTF8.self).contains("late"))
    }

    @Test func oneLineOverTheLimitIsTruncatedToo() async throws {
        let script = try CheckScript()
        let fx = try await RunnerFixture.checking(
            try script.write("head -c 3000000 /dev/zero | tr '\\0' 'x'\ntouch \(script.path("finished"))"))
        let id = try await fx.approvedThread()
        let report = try await fx.runner(id).run(fx.options(timeout: 60))

        #expect(report.check?.result == .passed)
        #expect(script.exists("finished"))
        #expect(report.check?.outputTruncated == true)
        let text = try fx.checkOutput(id)
        #expect(text.hasSuffix(truncationMarker))
        #expect(text.utf8.count <= 1_048_576 + 1 + truncationMarker.utf8.count)
        #expect(text.hasPrefix("xxxx"))
    }

    // MARK: stop

    @Test func stoppingDuringACheckRecordsItAsStoppedExactlyOnce() async throws {
        let script = try CheckScript()
        let body = """
            echo started
            sleep 300 &
            echo $! > \(script.path("child"))
            touch \(script.path("ready"))
            wait
            """
        let fx = try await RunnerFixture.checking(try script.write(body))
        let id = try await fx.approvedThread()
        let runner = fx.runner(id)
        let options = fx.options()

        let task = Task { try await runner.run(options) }
        // #require: a missed wait must not run on into indexing an empty array, which kills the whole run.
        try #require(await script.waitFor("ready"))
        await runner.stop()
        let report = try await task.value

        #expect(report.result == .succeeded, "the turn had already ended")
        #expect(report.check?.result == .stopped)
        #expect(try fx.checkStarts(id).count == 1)
        let ran = try fx.checkRuns(id)
        #expect(ran.count == 1)
        let stopped = try #require(ran.first)
        #expect(stopped.data["result"]?.stringValue == "stopped")
        #expect(stopped.data["synthetic"] == nil)
        #expect(ended(try fx.events(id)).count == 1)
        #expect(try fx.checkOutput(id) == "started\n")
        let contents = try fx.contents(id)
        #expect(contents.isHealthy)
        #expect(contents.openCheck == nil)
        let child = try script.pid("child")
        defer { kill(child, SIGKILL) }
        #expect(await FakeClaude.waitUntilGone(child))
        #expect(fx.contentsOfRunnerFile(id) == nil)
    }

    // MARK: after which turns

    @Test(arguments: [
        (["stream-events=1"], RunResult.succeeded),
        (["exit=2"], .failed),
        (["no-result"], .failed),
        (["fixture=\(FakeClaude.fixture("s5-budget.jsonl"))", "exit=1"], .budgetExceeded),
        (["hang-after=1"], .timedOut),
    ])
    func aCheckRunsAfterEveryTurnThatEndsOnItsOwn(directives: [String], expected: RunResult) async throws {
        let script = try CheckScript()
        let fx = try await RunnerFixture.checking(try script.write("echo checked"))
        let id = try await fx.approvedThread()
        var options = fx.options(timeout: expected == .timedOut ? 0.6 : 20)
        options.parentEnvironment["FAKE_CLAUDE"] = directives.joined(separator: ",")
        options.checkTimeoutOverride = 20

        let report = try await fx.runner(id).run(options)
        #expect(report.result == expected, "\(directives)")
        #expect(report.check?.result == .passed)
        #expect(report.check?.turn == 1)
        #expect(try fx.kinds(id).suffix(3) == ["turn.ended", "check.started", "check.ran"])
        #expect(try fx.checkOutput(id) == "checked\n")

        let lines = try fx.events(id).map { LogFormatter.describe($0) }
        #expect(lines.filter { $0.contains("check passed") }.count == 1)
    }

    @Test func noCheckRunsAfterAStoppedTurn() async throws {
        let script = try CheckScript()
        let fx = try await RunnerFixture.checking(try script.write("touch \(script.path("ran"))"))
        let id = try await fx.approvedThread()
        let ready = FakeClaude.scratch("ready")
        defer { try? FileManager.default.removeItem(atPath: ready) }
        let runner = fx.runner(id)
        let options = fx.options("ready=\(ready)", "hang-after=1")

        let task = Task { try await runner.run(options) }
        // #require: going on without it would stop a run that has not started, or write into a worktree
        // that does not exist yet.
        try #require(await pollUntil { FileManager.default.fileExists(atPath: ready) })
        await runner.stop()
        let report = try await task.value

        #expect(report.result == .stopped)
        #expect(report.check == nil)
        #expect(try fx.kinds(id).filter { $0.hasPrefix("check.") }.isEmpty)
        #expect(!script.exists("ran"))
    }

    @Test func noCheckRunsForAnInterruptedTurnOnlyForTheOneThatFollows() async throws {
        let script = try CheckScript()
        let fx = try await RunnerFixture.checking(try script.write("echo checked"))
        let id = try await fx.approvedThread()
        // A runner that died mid-turn: the turn is open in the log and nothing is running.
        let log = try EventLogWriter.open(at: fx.project.eventsURL(id))
        try await log.append(.turnStarted, turn: 1, data: ["session_id": "gone", "resume": false, "pid": nil])
        await log.close()

        let report = try await fx.runner(id).run(fx.options())
        #expect(report.turn == 2)
        #expect(report.result == .succeeded)
        #expect(ended(try fx.events(id)).map { $0.data["result"]?.stringValue } == ["interrupted", "succeeded"])
        #expect(try fx.checkStarts(id).map(\.turn) == [2])
        #expect(try fx.checkRuns(id).map(\.turn) == [2])
        #expect(!FileManager.default.fileExists(atPath: fx.project.checkOutputURL(id, turn: 1).path))
    }

    @Test func eachTurnGetsItsOwnCheckAndOutputFile() async throws {
        let script = try CheckScript()
        let body = "if [ -e \(script.path("second")) ]; then echo two; else touch \(script.path("second")); echo one; exit 1; fi"
        let fx = try await RunnerFixture.checking(try script.write(body))
        let id = try await fx.approvedThread()
        _ = try await fx.runner(id).run(fx.options())
        _ = try await fx.runner(id).run(fx.options(feedback: "fix the check"))

        let ran = try fx.checkRuns(id)
        #expect(ran.map(\.turn) == [1, 2])
        #expect(ran.map { $0.data["result"]?.stringValue } == ["failed", "passed"])
        #expect(ran.map { $0.data["output_ref"]?.stringValue } == ["checks/turn-1.log", "checks/turn-2.log"])
        #expect(try fx.checkOutput(id, turn: 1) == "one\n")
        #expect(try fx.checkOutput(id, turn: 2) == "two\n")
        #expect(ThreadStore(project: fx.project).state(of: id).lastCheck == "passed")
    }
}

// MARK: the event rules and recovery

@Suite(.processGate) struct CheckEventTests {
    private func tempLog() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("events.jsonl")
    }

    private func line(_ seq: Int, _ kind: String, turn: Int) -> String {
        #"{"v":1,"seq":\#(seq),"ts":"2026-10-13T09:00:00.000Z","turn":\#(turn),"kind":"\#(kind)","data":{}}"#
    }

    @Test func aSecondCheckStartedWhileOneIsOpenIsRejected() async throws {
        let log = try EventLogWriter.open(at: try tempLog())
        try await log.append(.checkStarted, turn: 1, data: ["command": "scripts/check.sh"])
        let seq = await log.nextSeq
        await #expect(throws: EventLogError.invalid(.checkStartedWhileOpen(turn: 1, open: 1, line: 0))) {
            try await log.append(.checkStarted, turn: 1, data: ["command": "scripts/check.sh"])
        }
        await #expect(throws: EventLogError.invalid(.checkStartedWhileOpen(turn: 2, open: 1, line: 0))) {
            try await log.append(.checkStarted, turn: 2, data: ["command": "scripts/check.sh"])
        }
        #expect(await log.nextSeq == seq, "a rejected append consumes no seq")
        #expect(await log.openCheck == 1)
    }

    @Test func aCheckRanWithNoneOpenIsRejected() async throws {
        let log = try EventLogWriter.open(at: try tempLog())
        await #expect(throws: EventLogError.invalid(.checkRanWithoutStart(turn: 1, line: 0))) {
            try await log.append(.checkRan, turn: 1, data: ["result": "passed"])
        }
        try await log.append(.checkStarted, turn: 1, data: ["command": "c"])
        await #expect(throws: EventLogError.invalid(.checkRanWithoutStart(turn: 2, line: 0))) {
            try await log.append(.checkRan, turn: 2, data: ["result": "passed"])
        }
        try await log.append(.checkRan, turn: 1, data: ["result": "passed"])
        await #expect(throws: EventLogError.invalid(.checkRanWithoutStart(turn: 1, line: 0))) {
            try await log.append(.checkRan, turn: 1, data: ["result": "passed"])
        }
        #expect(await log.openCheck == nil)
    }

    @Test func replayReportsTheSameRulesOnAHandBuiltLog() throws {
        let unmatched = [line(1, "check.ran", turn: 1)].joined(separator: "\n") + "\n"
        #expect(EventLogReader.parse(Data(unmatched.utf8)).problems == [.checkRanWithoutStart(turn: 1, line: 1)])

        let doubled = [line(1, "check.started", turn: 1), line(2, "check.started", turn: 1)]
            .joined(separator: "\n") + "\n"
        #expect(
            EventLogReader.parse(Data(doubled.utf8)).problems
                == [.checkStartedWhileOpen(turn: 1, open: 1, line: 2)])

        let url = try tempLog()
        try Data(doubled.utf8).write(to: url)
        #expect(throws: EventLogError.self) { _ = try EventLogWriter.open(at: url) }
    }

    @Test func anOpenCheckIsStateAndRecoveryClosesItAsInterrupted() async throws {
        let url = try tempLog()
        let open = [
            line(1, "turn.started", turn: 1), line(2, "turn.ended", turn: 1), line(3, "check.started", turn: 1),
        ].joined(separator: "\n") + "\n"
        try Data(open.utf8).write(to: url)

        let before = try EventLogReader.read(at: url)
        #expect(before.isHealthy, "an orphaned check is not damage")
        #expect(before.openCheck == 1)

        let log = try EventLogWriter.open(at: url)
        #expect(try await log.recoverOrphanedTurn() == nil)
        let recovered = try #require(try await log.recoverOrphanedCheck())
        #expect(recovered.kind == .checkRan)
        #expect(recovered.turn == 1)
        #expect(recovered.data["result"] == "interrupted")
        #expect(recovered.data["synthetic"] == true)
        #expect(try await log.recoverOrphanedCheck() == nil)
        await log.close()

        let after = try EventLogReader.read(at: url)
        #expect(after.isHealthy)
        #expect(after.openCheck == nil)
        #expect(after.events.filter { $0.kind == .checkRan }.count == 1)
    }

    @Test func theNextRunClosesACheckLeftOpenInTheLog() async throws {
        let script = try CheckScript()
        let fx = try await RunnerFixture.checking(try script.write("echo checked"))
        let id = try await fx.approvedThread()
        _ = try await fx.runner(id).run(fx.options())
        let log = try EventLogWriter.open(at: fx.project.eventsURL(id))
        try await log.append(.checkStarted, turn: 1, data: ["command": "left-open"])
        await log.close()
        #expect(ThreadStore(project: fx.project).state(of: id).openCheck == 1)

        let notices = NoticeBox()
        let report = try await fx.runner(id, notices: notices).run(fx.options(feedback: "again"))
        #expect(report.turn == 2)

        let ran = try fx.checkRuns(id)
        #expect(ran.map { $0.data["result"]?.stringValue } == ["passed", "interrupted", "passed"])
        #expect(ran[1].data["synthetic"] == true)
        #expect(ran[1].turn == 1)
        #expect(try fx.checkStarts(id).count == 3)
        #expect(notices.all.contains { if case .recoveredOrphanedCheck(1) = $0 { true } else { false } })
        #expect(try fx.contents(id).isHealthy)
    }

    @Test func abandoningClosesAnOpenCheckToo() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        _ = try await fx.runner(id).run(fx.options())
        let log = try EventLogWriter.open(at: fx.project.eventsURL(id))
        try await log.append(.checkStarted, turn: 1, data: ["command": "left-open"])
        await log.close()

        try await fx.service.abandon(id: id)
        #expect(try fx.kinds(id).suffix(2) == ["check.ran", "review.decision"])
        #expect(try fx.contents(id).openCheck == nil)
    }

    @Test func classificationFollowsTheCauseThenTheExit() {
        func exit(_ termination: Termination, _ cause: StopCause = .natural) -> ProcessExit {
            ProcessExit(
                termination: termination, cause: cause, durationMs: 1, escalatedToKill: false, sweptProcesses: 0,
                outputTruncated: false, lastLineAfterLimit: nil, stderrTail: "", drainTimedOut: false)
        }
        #expect(CheckRunner.classify(exit(.exited(0))) == .passed)
        #expect(CheckRunner.classify(exit(.exited(1))) == .failed)
        #expect(CheckRunner.classify(exit(.signaled(SIGSEGV))) == .failed)
        #expect(CheckRunner.classify(exit(.lost)) == .failed)
        #expect(CheckRunner.classify(exit(.exited(0), .stopped)) == .stopped, "a stop is never a pass")
        #expect(CheckRunner.classify(exit(.signaled(SIGTERM), .timedOut)) == .timedOut)
        #expect(CheckRunner.classify(nil) == .failed)
    }

    @Test func theLogLineSaysHowTheCheckEnded() {
        func describe(_ data: JSONValue) -> String {
            LogFormatter.describe(
                Event(seq: 9, ts: "2026-10-13T09:00:00.000Z", turn: 2, kind: .checkRan, data: data))
        }
        #expect(describe(["result": "passed", "exit_code": 0, "duration_ms": 93000]).hasSuffix("t2  check passed  93s"))
        #expect(describe(["result": "failed", "exit_code": 1]).hasSuffix("check failed (exit 1)"))
        #expect(describe(["result": "failed", "exit_code": nil, "signal": 11]).hasSuffix("check failed (signal 11)"))
        #expect(describe(["result": "timed_out", "exit_code": nil, "signal": 15]).hasSuffix("check timed out"))
        #expect(describe(["result": "stopped"]).hasSuffix("check stopped"))
        #expect(describe(["result": "interrupted", "synthetic": true]).hasSuffix("check interrupted"))
        #expect(describe(["result": "passed", "output_truncated": true]).hasSuffix("check passed  output truncated"))
    }
}
