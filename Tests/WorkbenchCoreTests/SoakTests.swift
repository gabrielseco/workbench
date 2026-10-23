import Foundation
import Testing

@testable import WorkbenchCore

// MARK: helpers

/// The built `workbench` CLI, for tests that need a real, killable runner process.
enum WorkbenchBinary {
    static let executable: URL = {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var candidates = [".build/debug/workbench", ".build/release/workbench"].map { root.appendingPathComponent($0) }
        for bundle in Bundle.allBundles where bundle.bundleURL.pathExtension == "xctest" {
            candidates.insert(bundle.bundleURL.deletingLastPathComponent().appendingPathComponent("workbench"), at: 0)
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) } ?? candidates[0]
    }()
}

/// Open descriptors in this process, from the kernel's own list.
func openDescriptorCount() -> Int {
    let bytes = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, nil, 0)
    guard bytes > 0 else { return -1 }
    var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / MemoryLayout<proc_fdinfo>.size + 16)
    let written = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * MemoryLayout<proc_fdinfo>.size))
    return written > 0 ? Int(written) / MemoryLayout<proc_fdinfo>.size : -1
}

/// Whether a process's whole command line is exactly `commandLine` (`pgrep -f` with an anchored pattern, run
/// through the same bounded runner). Anchored on purpose: an unanchored match also finds any shell whose
/// *text* mentions the string, which is how a first version reported a leak that was only a wrapper.
func processExists(commandLine: String) async -> Bool {
    let escaped = commandLine.replacingOccurrences(of: ".", with: "\\.")
    let pgrep = GitRunner(executable: URL(fileURLWithPath: "/usr/bin/pgrep"), environment: [:], timeout: 10)
    guard let result = try? await pgrep.run(["-f", "^\(escaped)$"], in: URL(fileURLWithPath: "/tmp")) else {
        return false
    }
    return result.succeeded && !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

private func waitForPath(_ path: String, timeout: TimeInterval = Patience.limit) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if FileManager.default.fileExists(atPath: path) { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return FileManager.default.fileExists(atPath: path)
}

// MARK: a real runner process, killed

@Suite(.processGate) struct CrashRecoveryTests {
    @Test func aKilledRunnerLeavesAnOpenTurnAndAnOrphanThatTheNextRunCleansUp() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        let ready = FakeClaude.scratch("ready")
        let pidFile = FakeClaude.scratch("gc.pid")
        defer {
            try? FileManager.default.removeItem(atPath: ready)
            try? FileManager.default.removeItem(atPath: pidFile)
        }

        // The real CLI, as its own process, running a turn that hangs.
        var spawn = SpawnRequest(
            executable: WorkbenchBinary.executable, arguments: ["run"],
            environment: [
                "PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "USER": NSUserName(),
                "FAKE_CLAUDE": "ready=\(ready),grandchild=\(pidFile),hang-after=1",
            ],
            workingDirectory: fx.repo, timeout: 120)
        spawn.killGrace = 30
        // This runner is only here to start and watch the CLI. Its job in production is to sweep a dead
        // child's descendants, which is exactly what this test needs to be left alone: so it must never
        // track them. (With the default 100 ms snapshot the test passed or failed on runner speed.)
        spawn.snapshotInterval = 3600
        let cli = try ProcessRunner.start(spawn)
        try #require(await waitForPath(ready), "the fake claude should be up inside the worktree")
        let grandchild = try #require(pid_t(try String(contentsOfFile: pidFile, encoding: .utf8)))
        defer { kill(grandchild, SIGKILL) }

        #expect(cli.trackedDescendants().isEmpty, "the watching runner must not have seen the tool child")

        // The runner dies without a chance to clean up. Its child is in its own process group and stays.
        kill(cli.pid, SIGKILL)
        for await event in cli.events { if case .exited = event { break } }
        #expect(FakeClaude.alive(grandchild), "a tool child outlives its SIGKILLed parent")
        let open = try fx.contents(id)
        #expect(open.openTurn == 1, "the turn is left open in the log")

        // Next run: recovered, swept, and a new turn that succeeds.
        let notices = NoticeBox()
        let report = try await fx.runner(id, notices: notices).run(fx.options())
        #expect(report.result == .succeeded)

        let ends = ended(try fx.events(id))
        #expect(ends.map { $0.data["result"]?.stringValue } == ["interrupted", "succeeded"])
        #expect(try fx.contents(id).isHealthy)
        #expect(
            notices.all.contains { if case .recoveredOrphanedTurn(1) = $0 { true } else { false } })
        #expect(await FakeClaude.waitUntilGone(grandchild), "what the dead runner left behind is swept")
        #expect(await FakeClaude.waitUntilGone(pid_t(cli.pid)), "and so is the runner")
    }

    @Test func aRunnerTerminatedByHandRecordsTheTurnAsStopped() async throws {
        // SIGTERM (what `workbench stop` sends) is the clean path: the runner writes the end itself.
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        let ready = FakeClaude.scratch("ready")
        defer { try? FileManager.default.removeItem(atPath: ready) }

        var spawn = SpawnRequest(
            executable: WorkbenchBinary.executable, arguments: ["run"],
            environment: [
                "PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "USER": NSUserName(),
                "FAKE_CLAUDE": "ready=\(ready),hang-after=1",
            ],
            workingDirectory: fx.repo, timeout: 120)
        spawn.killGrace = 30
        // This runner is only here to start and watch the CLI. Its job in production is to sweep a dead
        // child's descendants, which is exactly what this test needs to be left alone: so it must never
        // track them. (With the default 100 ms snapshot the test passed or failed on runner speed.)
        spawn.snapshotInterval = 3600
        let cli = try ProcessRunner.start(spawn)
        try #require(await waitForPath(ready))

        #expect(fx.service.requestStop(id: id) == .signalled(pid: cli.pid))
        var exit: ProcessExit?
        for await event in cli.events { if case .exited(let e) = event { exit = e } }

        #expect(exit?.termination == .exited(3), "`run` exits 3 when stopped")
        let ends = ended(try fx.events(id))
        #expect(ends.map { $0.data["result"]?.stringValue } == ["stopped"])
        #expect(try fx.contents(id).isHealthy)
    }
}

// MARK: the soak

private let soakEnabled = ProcessInfo.processInfo.environment["WORKBENCH_SOAK"] == "1"
private let soakRuns = Int(ProcessInfo.processInfo.environment["WORKBENCH_SOAK_RUNS"] ?? "") ?? 100

/// Many runs in one process, the way the app will hold the runner, checking that nothing accumulates.
/// Off by default; CI runs it as its own step so descriptor counts are not disturbed by other suites:
/// `WORKBENCH_SOAK=1 swift test --filter SoakTests`.
@Suite(.serialized, .enabled(if: soakEnabled)) struct SoakTests {
    private struct Scenario {
        var name: String
        var directives: [String]
        var expected: RunResult
        var timeout: TimeInterval = 30
        /// Stop the turn from outside once it is up.
        var stopAfterReady = false
    }

    /// Twenty scenarios; the loop cycles through them, so 100 runs is each five times.
    private static let scenarios: [Scenario] = {
        var list: [Scenario] = []
        for events in [0, 3, 12, 40, 5, 8, 1, 20, 2, 6, 15, 4] {
            list.append(Scenario(name: "ok-\(events)", directives: ["stream-events=\(events)"], expected: .succeeded))
        }
        list.append(Scenario(name: "exit-2", directives: ["exit=2"], expected: .failed))
        list.append(Scenario(name: "crash", directives: ["crash-after=1"], expected: .failed))
        list.append(Scenario(name: "killed", directives: ["die-after=2"], expected: .failed))
        list.append(Scenario(name: "no-result", directives: ["no-result"], expected: .failed))
        list.append(Scenario(name: "hang", directives: ["hang-after=1"], expected: .timedOut, timeout: 0.7))
        list.append(Scenario(name: "flood", directives: ["flood=2000000"], expected: .succeeded))
        list.append(Scenario(name: "stop", directives: ["hang-after=1"], expected: .stopped, stopAfterReady: true))
        list.append(Scenario(name: "pipe-holder", directives: ["delay-ms=120"], expected: .succeeded))
        return list
    }()

    @Test func manyThreadsEachWithRunWorktreeAndTeardown() async throws {
        let fx = try await RunnerFixture()
        let before = openDescriptorCount()
        var results: [String: Int] = [:]
        var allTurns = 0
        var spawnedPIDs: [pid_t] = []

        for i in 0..<soakRuns {
            let scenario = Self.scenarios[i % Self.scenarios.count]
            let id = try await fx.approvedThread("soak\(i)")

            var options = fx.options(timeout: scenario.timeout)
            var directives = scenario.directives
            let ready = FakeClaude.scratch("ready")
            var pidFile: String?
            if scenario.stopAfterReady { directives.append("ready=\(ready)") }
            if scenario.name == "pipe-holder" {
                pidFile = FakeClaude.scratch("gc.pid")
                directives.append("grandchild=\(pidFile!)")
            }
            options.parentEnvironment["FAKE_CLAUDE"] = directives.joined(separator: ",")

            let runner = fx.runner(id)
            let report: TurnReport
            if scenario.stopAfterReady {
                let task = Task { try await runner.run(options) }
                try #require(await waitForPath(ready), "\(scenario.name) #\(i): never became ready")
                await runner.stop()
                report = try await task.value
            } else {
                report = try await runner.run(options)
            }
            try? FileManager.default.removeItem(atPath: ready)

            #expect(report.result == scenario.expected, "\(scenario.name) #\(i): got \(report.result)")
            results[report.result.rawValue, default: 0] += 1
            allTurns += 1

            // The invariants, for every single run.
            let contents = try fx.contents(id)
            #expect(contents.isHealthy, "\(scenario.name) #\(i): log not healthy: \(contents.problems)")
            #expect(contents.openTurn == nil, "\(scenario.name) #\(i): turn left open")
            let started = contents.events.filter { $0.kind == .turnStarted }.count
            let ends = ended(contents.events)
            #expect(started == 1 && ends.count == 1, "\(scenario.name) #\(i): \(started) started, \(ends.count) ended")
            #expect(ends.first?.data["lost"] == nil, "\(scenario.name) #\(i): a child was reaped by something else")
            #expect(fx.contentsOfRunnerFile(id) == nil, "\(scenario.name) #\(i): runner.json left behind")

            if let pidFile, let text = try? String(contentsOfFile: pidFile, encoding: .utf8), let pid = pid_t(text) {
                spawnedPIDs.append(pid)
                try? FileManager.default.removeItem(atPath: pidFile)
            }

            try await fx.service.abandon(id: id, force: true)
        }

        // Nothing accumulated.
        #expect(results.values.reduce(0, +) == soakRuns)
        for pid in spawnedPIDs { #expect(await FakeClaude.waitUntilGone(pid), "grandchild \(pid) outlived its turn") }
        // The fake runs as its path plus the arguments it was given; anything starting with that path is it.
        #expect(!(await processExists(commandLine: "sleep 300")), "a tool child is still running")
        let listing = GitRunner(executable: URL(fileURLWithPath: "/bin/ps"), environment: [:], timeout: 10)
        let ps = try await listing.run(["-axo", "command="], in: URL(fileURLWithPath: "/tmp"))
        let strays = ps.stdout.split(separator: "\n").filter { $0.hasPrefix(FakeClaude.executable.path) }
        #expect(strays.isEmpty, "a fake claude is still running: \(strays)")

        let after = openDescriptorCount()
        #expect(after - before <= 4, "descriptors grew from \(before) to \(after) over \(soakRuns) runs")

        let list = try await fx.git.run(["worktree", "list", "--porcelain"], in: fx.repo)
        #expect(list.stdout.components(separatedBy: "worktree ").count == 2, "worktrees left behind:\n\(list.stdout)")
        let admin = fx.repo.appendingPathComponent(".git/worktrees")
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: admin.path)) ?? []
        #expect(leftovers.isEmpty, "worktree admin entries left: \(leftovers)")
        #expect(!FileManager.default.fileExists(atPath: fx.repo.appendingPathComponent(".git/index.lock").path))
        let locked = leftovers.filter {
            FileManager.default.fileExists(atPath: admin.appendingPathComponent("\($0)/locked").path)
        }
        #expect(locked.isEmpty, "locked worktrees: \(locked)")

        print("SOAK fake runs=\(soakRuns) results=\(results.sorted { $0.key < $1.key }) fds \(before)->\(after)")
    }

    @Test func aChildThatIgnoresSigtermIsKilledWithinTheDefaultGrace() async throws {
        // The plan's number: killed within 5s + 1s. This one uses the real default grace.
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        let ready = FakeClaude.scratch("ready")
        defer { try? FileManager.default.removeItem(atPath: ready) }
        var options = fx.options("ready=\(ready)", "ignore-term", "hang-after=1", timeout: 60, grace: 5)
        options.killGrace = 5

        let runner = fx.runner(id)
        let task = Task { try await runner.run(options) }
        try #require(await waitForPath(ready))
        let started = Date()
        await runner.stop()
        let report = try await task.value
        let elapsed = Date().timeIntervalSince(started)

        #expect(report.result == .stopped)
        // Only the floor is a property of the code (it waited out the grace); the ceiling is the runner.
        #expect(elapsed >= 4.9 && elapsed <= Patience.limit, "took \(elapsed)s")
        let end = try #require(ended(try fx.events(id)).first)
        #expect(end.data["escalated_to_kill"] == true)
    }
}
