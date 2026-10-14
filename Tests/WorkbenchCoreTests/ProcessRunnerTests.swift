import Foundation
import Testing

@testable import WorkbenchCore

// MARK: helpers

private struct Collected {
    var events: [ProcessEvent]
    var exit: ProcessExit

    var lines: [String] {
        events.compactMap { if case .line(let l) = $0 { l } else { nil } }
    }
    var oversized: [(preview: String, totalBytes: Int)] {
        events.compactMap {
            if case .oversizedLine(let p, let n) = $0 { (p, n) } else { nil }
        }
    }
}

private func collect(_ run: ProcessRun) async throws -> Collected {
    var events: [ProcessEvent] = []
    for await event in run.events { events.append(event) }
    guard case .exited(let exit)? = events.last else {
        throw ProcessTestError.noTerminalEvent(events.count)
    }
    return Collected(events: events, exit: exit)
}

private enum ProcessTestError: Error { case noTerminalEvent(Int) }

private func request(
    _ directives: String..., args: [String] = ["-p", "--", "hi"], timeout: TimeInterval = 30,
    cwd: URL = URL(fileURLWithPath: "/tmp"), environment: [String: String]? = nil,
    tweak: (inout SpawnRequest) -> Void = { _ in }
) -> SpawnRequest {
    var r = SpawnRequest(
        executable: FakeClaude.executable, arguments: args,
        environment: environment ?? ["FAKE_CLAUDE": directives.joined(separator: ","), "PATH": "/usr/bin:/bin"],
        workingDirectory: cwd, timeout: timeout)
    r.killGrace = 5
    tweak(&r)
    return r
}

private func waitForFile(_ path: String, timeout: TimeInterval = Patience.limit) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if FileManager.default.fileExists(atPath: path) { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return false
}

private func waitUntil(timeout: TimeInterval = Patience.limit, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}

private func readJSON(_ path: String) throws -> [String: Any] {
    try #require(
        JSONSerialization.jsonObject(with: try Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
}

// MARK: pure pieces

@Suite struct LineSplitterTests {
    private func run(_ chunks: [String], max: Int = 1000, preview: Int = 8) -> [LineSplitter.Output] {
        var splitter = LineSplitter(maxLineBytes: max, previewBytes: preview)
        var out: [LineSplitter.Output] = []
        for chunk in chunks { splitter.feed(Data(chunk.utf8)) { out.append($0) } }
        splitter.finish { out.append($0) }
        return out
    }

    private func line(_ s: String) -> LineSplitter.Output { .line(Data(s.utf8)) }

    @Test func splitsAcrossChunkBoundaries() {
        #expect(run(["ab", "c\nde", "f\n", "gh"]) == [line("abc"), line("def"), line("gh")])
    }

    @Test func keepsEmptyLinesAndAddsNoPhantomLineAfterTheLastNewline() {
        #expect(run(["a\n\nb\n"]) == [line("a"), line(""), line("b")])
    }

    @Test func aFinalLineWithoutNewlineIsStillALine() {
        #expect(run(["x\ny"]) == [line("x"), line("y")])
    }

    @Test func aLineExactlyAtTheLimitIsNotOversized() {
        #expect(run(["12345\n"], max: 5) == [line("12345")])
    }

    @Test func oversizedLineKeepsAPreviewAndTheRealSizeAndRecovers() {
        let long = String(repeating: "x", count: 50)
        #expect(
            run(["ok\n", long.prefix(20) + "", String(long.dropFirst(20)) + "\nnext\n"], max: 10, preview: 4)
                == [line("ok"), .oversized(preview: Data("xxxx".utf8), totalBytes: 50), line("next")])
    }

    @Test func memoryStaysBoundedForOneEnormousLine() {
        var splitter = LineSplitter(maxLineBytes: 1024, previewBytes: 16)
        var outputs: [LineSplitter.Output] = []
        let chunk = Data(repeating: 0x61, count: 1 << 20)
        for _ in 0..<64 { splitter.feed(chunk) { outputs.append($0) } }
        splitter.finish { outputs.append($0) }
        #expect(outputs == [.oversized(preview: Data(repeating: 0x61, count: 16), totalBytes: 64 << 20)])
    }

    @Test func multiByteCharactersSurviveASplitAcrossChunks() {
        let bytes = Array("héllo\n".utf8)
        var splitter = LineSplitter(maxLineBytes: 100)
        var out: [LineSplitter.Output] = []
        splitter.feed(Data(bytes[0..<2])) { out.append($0) }  // cuts the é in half
        splitter.feed(Data(bytes[2...])) { out.append($0) }
        #expect(out == [.line(Data("héllo".utf8))])
    }
}

@Suite struct ProcessTreeTests {
    @Test func findsAChildAndKnowsWhenItIsGone() async throws {
        let fd = open("/dev/null", O_WRONLY)
        defer { close(fd) }
        let pid = try Spawner.spawn(
            executable: "/bin/sleep", arguments: ["30"], environment: [:], workingDirectory: "/tmp",
            stdout: fd, stderr: fd)
        defer { kill(pid, SIGKILL); var s: Int32 = 0; waitpid(pid, &s, 0) }

        let member = try #require(ProcessTree.descendants(of: getpid()).first { $0.pid == pid })
        #expect(ProcessTree.isAlive(member))

        kill(pid, SIGKILL)
        var status: Int32 = 0
        waitpid(pid, &status, 0)  // reaped: the pid no longer exists
        #expect(!ProcessTree.isAlive(member))
    }

    @Test func aRecycledPidIsNotTheSameMember() {
        let me = ProcessTree.member(for: getpid())!
        var other = me
        other.startSeconds += 5
        #expect(ProcessTree.isAlive(me))
        #expect(!ProcessTree.isAlive(other))
    }
}

// MARK: the runner

@Suite struct ProcessRunnerTests {
    // MARK: normal operation

    @Test func streamsLinesInOrderThenExactlyOneExit() async throws {
        let run = try ProcessRunner.start(request("stream-events=3"))
        let result = try await collect(run)

        #expect(result.events.first == .started(pid: run.pid))
        #expect(result.events.filter { if case .exited = $0 { true } else { false } }.count == 1)
        #expect(result.lines.count == 6)  // init + 3 stream events + assistant + result
        #expect(result.lines.first?.contains("\"subtype\":\"init\"") == true)
        #expect(result.lines.last?.contains("\"type\":\"result\"") == true)
        #expect(result.exit.termination == .exited(0))
        #expect(result.exit.cause == .natural)
        #expect(!result.exit.escalatedToKill)
        #expect(!result.exit.outputTruncated)
        #expect(!result.exit.drainTimedOut)
    }

    @Test func reportsExitCodesAndCrashesAndKills() async throws {
        #expect(try await collect(try ProcessRunner.start(request("exit=2"))).exit.termination == .exited(2))

        let crashed = try await collect(try ProcessRunner.start(request("crash-after=1")))
        #expect(crashed.exit.termination == .exited(70))
        #expect(crashed.lines.count == 1)

        let killed = try await collect(try ProcessRunner.start(request("die-after=2")))
        #expect(killed.exit.termination == .signaled(SIGKILL))
        #expect(killed.lines.count == 2)
    }

    @Test func aMissingResultLineIsJustTheEndOfTheStream() async throws {
        let result = try await collect(try ProcessRunner.start(request("no-result")))
        #expect(result.exit.termination == .exited(0))
        #expect(result.lines.count == 2)
    }

    @Test func stderrTailIsCapturedForDiagnosis() async throws {
        let dir = FakeClaude.scratch("sessions")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let args = ["-p", "--session-id", "abc", "--", "x"]
        _ = try await collect(try ProcessRunner.start(request("sessions=\(dir)", args: args)))
        let again = try await collect(try ProcessRunner.start(request("sessions=\(dir)", args: args)))
        #expect(again.exit.termination == .exited(1))
        #expect(again.exit.stderrTail.contains("already in use"))
        #expect(again.lines.isEmpty)
    }

    // MARK: what the child gets (rule 8)

    @Test func theChildHoldsNoDescriptorsButStdio_notEvenTheEventLog() async throws {
        // An open event log holds a descriptor and an exclusive lock in this process. A child must not
        // inherit either: the intermittent `alreadyOpen` seen in the worktree PR came from exactly this.
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wb-fd-\(UUID().uuidString)/events.jsonl")
        let log = try EventLogWriter.open(at: logURL)
        try await log.append(.threadCreated)
        let stray = open("/dev/null", O_RDONLY)  // an arbitrary extra descriptor of ours
        defer {
            close(stray)
            try? FileManager.default.removeItem(at: logURL.deletingLastPathComponent())
        }

        let dump = FakeClaude.scratch("dump.json")
        defer { try? FileManager.default.removeItem(atPath: dump) }
        let result = try await collect(try ProcessRunner.start(request("dump=\(dump)")))
        #expect(result.exit.termination == .exited(0))

        let info = try readJSON(dump)
        let fds = try #require(info["fds"] as? [[String: Any]])
        let numbers = fds.compactMap { $0["fd"] as? Int }.sorted()
        #expect(numbers == [0, 1, 2], "child descriptors: \(fds)")
        #expect(!fds.contains { ($0["path"] as? String)?.contains("events.jsonl") == true })

        // And the lock is ours alone: a second writer is refused, and we can still append.
        #expect(throws: EventLogError.alreadyOpen(path: logURL.path)) {
            _ = try EventLogWriter.open(at: logURL, lockTimeout: 0)
        }
        try await log.append(.goalSaved)
        await log.close()
    }

    @Test func stdinIsDevNullAndStdoutStderrArePipes() async throws {
        let dump = FakeClaude.scratch("dump.json")
        defer { try? FileManager.default.removeItem(atPath: dump) }
        _ = try await collect(try ProcessRunner.start(request("dump=\(dump)")))
        let info = try readJSON(dump)
        #expect(info["stdin_eof"] as? Bool == true)
        let fds = try #require(info["fds"] as? [[String: Any]])
        #expect(fds.first { $0["fd"] as? Int == 0 }?["path"] as? String == "/dev/null")
    }

    @Test func theChildSeesExactlyTheEnvironmentItWasGiven() async throws {
        let dump = FakeClaude.scratch("dump.json")
        defer { try? FileManager.default.removeItem(atPath: dump) }
        let env = ["FAKE_CLAUDE": "dump=\(dump)", "ONLY": "this"]
        // Pollute our own environment to prove nothing leaks through.
        setenv("WB_LEAK_CANARY", "leaked", 1)
        defer { unsetenv("WB_LEAK_CANARY") }

        _ = try await collect(try ProcessRunner.start(request(environment: env)))
        let seen = try #require(try readJSON(dump)["env"] as? [String: String])
        #expect(seen["ONLY"] == "this")
        #expect(seen["WB_LEAK_CANARY"] == nil)
        #expect(seen["HOME"] == nil)
        #expect(Set(seen.keys).subtracting(["FAKE_CLAUDE", "ONLY", "__CF_USER_TEXT_ENCODING"]).isEmpty)
    }

    @Test func workingDirectoryAndOwnProcessGroup() async throws {
        let dump = FakeClaude.scratch("dump.json")
        defer { try? FileManager.default.removeItem(atPath: dump) }
        let cwd = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let run = try ProcessRunner.start(request("dump=\(dump)", cwd: cwd))
        _ = try await collect(run)

        let info = try readJSON(dump)
        #expect((info["cwd"] as? String).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } == cwd.path)
        #expect(info["pgid"] as? Int == Int(run.pid), "leads its own group")
        #expect(Int(getpgrp()) != Int(run.pid))
    }

    @Test func launchFailureIsAnErrorNotAHang() {
        var r = request()
        r.executable = URL(fileURLWithPath: "/nonexistent/claude")
        #expect(throws: SpawnError.notExecutable("/nonexistent/claude")) {
            _ = try ProcessRunner.start(r)
        }
    }

    // MARK: stopping

    @Test func stopSendsSigtermAndTheChildExitsOnItsOwn() async throws {
        let ready = FakeClaude.scratch("ready")
        defer { try? FileManager.default.removeItem(atPath: ready) }
        let run = try ProcessRunner.start(request("ready=\(ready)", "hang-after=1"))
        try #require(await waitForFile(ready))

        run.stop()
        run.stop()  // idempotent
        let result = try await collect(run)
        #expect(result.exit.cause == .stopped)
        #expect(result.exit.termination == .exited(143))
        #expect(!result.exit.escalatedToKill)
        // No time bound: `!escalatedToKill` is the property (it left on SIGTERM, inside the grace).
    }

    @Test func timeoutStopsTheChildAndSaysWhy() async throws {
        let result = try await collect(
            try ProcessRunner.start(request("hang-after=1", timeout: 0.5)))
        #expect(result.exit.cause == .timedOut)
        // 143 if the handler was installed in time, SIGTERM otherwise: either way it is not a success.
        #expect(result.exit.termination == .exited(143) || result.exit.termination == .signaled(SIGTERM))
        #expect(!result.exit.escalatedToKill)
    }

    @Test func aChildThatIgnoresSigtermIsKilledAfterTheGrace() async throws {
        let ready = FakeClaude.scratch("ready")
        defer { try? FileManager.default.removeItem(atPath: ready) }
        let run = try ProcessRunner.start(
            request("ready=\(ready)", "ignore-term", "hang-after=1") { $0.killGrace = 0.5 })
        try #require(await waitForFile(ready))

        let started = Date()
        run.stop()
        let result = try await collect(run)
        #expect(result.exit.cause == .stopped)
        #expect(result.exit.escalatedToKill)
        #expect(result.exit.termination == .signaled(SIGKILL))
        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed >= 0.45, "it waited out the grace before killing: \(elapsed)")
    }

    @Test func escalationKillsAToolChildInAnotherProcessGroup() async throws {
        let ready = FakeClaude.scratch("ready")
        let pidFile = FakeClaude.scratch("gc.pid")
        defer {
            try? FileManager.default.removeItem(atPath: ready)
            try? FileManager.default.removeItem(atPath: pidFile)
        }
        let run = try ProcessRunner.start(
            request("ready=\(ready)", "grandchild=\(pidFile)", "ignore-term", "hang-after=1") {
                $0.killGrace = 0.4
            })
        try #require(await waitForFile(ready))
        let grandchild = try #require(pid_t(try String(contentsOfFile: pidFile, encoding: .utf8)))
        defer { kill(grandchild, SIGKILL) }
        #expect(getpgid(grandchild) == grandchild, "own group: a group kill alone would miss it (S6)")
        #expect(
            await waitUntil { run.trackedDescendants().contains(grandchild) },
            "the runner should have noticed it before the parent died")

        run.stop()
        let result = try await collect(run)
        #expect(result.exit.escalatedToKill)
        #expect(await FakeClaude.waitUntilGone(grandchild), "tool child must not outlive the turn")
    }

    @Test func aToolChildLeftBehindByAnUnexpectedDeathIsSwept() async throws {
        let ready = FakeClaude.scratch("ready")
        let pidFile = FakeClaude.scratch("gc.pid")
        defer {
            try? FileManager.default.removeItem(atPath: ready)
            try? FileManager.default.removeItem(atPath: pidFile)
        }
        let run = try ProcessRunner.start(request("ready=\(ready)", "grandchild=\(pidFile)", "hang-after=1"))
        try #require(await waitForFile(ready))
        let grandchild = try #require(pid_t(try String(contentsOfFile: pidFile, encoding: .utf8)))
        defer { kill(grandchild, SIGKILL) }
        #expect(await waitUntil { run.trackedDescendants().contains(grandchild) })

        kill(run.pid, SIGKILL)  // nobody asked it to stop: `claude` simply dies
        let result = try await collect(run)
        #expect(result.exit.cause == .natural)
        #expect(result.exit.termination == .signaled(SIGKILL))
        #expect(result.exit.sweptProcesses == 1)
        #expect(await FakeClaude.waitUntilGone(grandchild))
    }

    @Test func aChildHoldingThePipesOpenDoesNotHoldTheTurnOpen() async throws {
        // The fake's grandchild inherits stdout/stderr and sleeps for minutes. The parent exits normally.
        let pidFile = FakeClaude.scratch("gc.pid")
        defer { try? FileManager.default.removeItem(atPath: pidFile) }
        let started = Date()
        let result = try await collect(
            try ProcessRunner.start(
                request("grandchild=\(pidFile)", "delay-ms=250") { $0.drainGrace = 1 }))
        let grandchild = try #require(pid_t(try String(contentsOfFile: pidFile, encoding: .utf8)))
        defer { kill(grandchild, SIGKILL) }

        #expect(result.exit.termination == .exited(0))
        #expect(result.lines.count == 3)
        #expect(Date().timeIntervalSince(started) < Patience.limit)
        #expect(await FakeClaude.waitUntilGone(grandchild))
        #expect(result.exit.sweptProcesses == 1 || result.exit.drainTimedOut)
    }

    @Test func abandoningTheStreamStopsTheChild() async throws {
        let ready = FakeClaude.scratch("ready")
        defer { try? FileManager.default.removeItem(atPath: ready) }
        let pid: pid_t
        do {
            let run = try ProcessRunner.start(request("ready=\(ready)", "hang-after=1"))
            pid = run.pid
            try #require(await waitForFile(ready))
            var iterator = run.events.makeAsyncIterator()
            _ = await iterator.next()  // .started
            // iterator and run go out of scope here: nobody is listening any more
        }
        #expect(await FakeClaude.waitUntilGone(pid, within: 8), "an unwatched child must not keep running")
    }

    // MARK: bounds

    @Test func anOversizedLineIsReportedWithItsRealSizeAndTheStreamContinues() async throws {
        let result = try await collect(
            try ProcessRunner.start(request("flood=200000") { $0.maxLineBytes = 10_000 }))
        #expect(result.oversized.count == 1)
        #expect(result.oversized[0].totalBytes > 200_000)
        #expect(result.oversized[0].preview.utf8.count <= 4096)
        #expect(result.lines.last?.contains("\"type\":\"result\"") == true)
        #expect(result.exit.termination == .exited(0))
    }

    @Test func outputPastTheLimitIsDroppedButTheResultLineIsKept() async throws {
        let result = try await collect(
            try ProcessRunner.start(request("stream-events=3000") { $0.maxOutputBytes = 5_000 }))
        #expect(result.exit.outputTruncated)
        #expect(result.lines.count < 100)
        #expect(result.exit.lastLineAfterLimit?.contains("\"type\":\"result\"") == true)
        #expect(result.exit.termination == .exited(0), "the child must not have blocked on a full pipe")
    }

    @Test func aBadLinePassesThroughAndAnUnterminatedTailIsKept() async throws {
        let result = try await collect(try ProcessRunner.start(request("invalid-line", "partial-tail")))
        #expect(result.lines.contains("this is not json {"))
        #expect(result.lines.last?.hasSuffix("}") == true)
        #expect(result.lines.count == 4)
    }

    // MARK: the invariant

    @Test func everyRunEndsWithExactlyOneExitWhateverHappened() async throws {
        let scenarios: [[String]] = [
            [], ["exit=3"], ["crash-after=1"], ["die-after=1"], ["no-result"], ["invalid-line"],
            ["partial-tail"], ["flood=50000"], ["stream-events=50"],
        ]
        for directives in scenarios {
            var r = request()
            r.environment["FAKE_CLAUDE"] = directives.joined(separator: ",")
            let result = try await collect(try ProcessRunner.start(r))
            let exits = result.events.filter { if case .exited = $0 { true } else { false } }
            #expect(exits.count == 1, "\(directives)")
            #expect(result.events.first == .started(pid: result.events.compactMap {
                if case .started(let p) = $0 { p } else { nil }
            }.first ?? 0))
        }
    }

    @Test func manyRunsInSequenceLeaveNothingBehind() async throws {
        var pids: [pid_t] = []
        for _ in 0..<60 {
            let run = try ProcessRunner.start(request())
            pids.append(run.pid)
            let result = try await collect(run)
            #expect(result.exit.termination == .exited(0))
        }
        #expect(pids.allSatisfy { !FakeClaude.alive($0) }, "no leftover processes")
    }

    @Test func manyRunsAtOnceAllEnd() async throws {
        try await withThrowingTaskGroup(of: Termination.self) { group in
            for i in 0..<25 {
                group.addTask {
                    let run = try ProcessRunner.start(
                        request(i % 5 == 0 ? "exit=1" : "stream-events=5"))
                    return try await collect(run).exit.termination
                }
            }
            var results: [Termination] = []
            for try await t in group { results.append(t) }
            #expect(results.count == 25)
            #expect(results.filter { $0 == .exited(1) }.count == 5)
            #expect(results.filter { $0 == .exited(0) }.count == 20)
            #expect(!results.contains(.lost))
        }
    }
}
