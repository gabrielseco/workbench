import Foundation
import Testing

@testable import WorkbenchCore

extension RunnerFixture {
    /// The project's config as written, for what takes it as an argument (`newThread` needs it to know `max_active_threads`).
    func loadedConfig() throws -> Config { try Config.load(from: project.configURL) }
}

private let soakEnabled = ProcessInfo.processInfo.environment["WORKBENCH_SOAK"] == "1"
private let soakRounds = Int(ProcessInfo.processInfo.environment["WORKBENCH_SOAK_ROUNDS"] ?? "") ?? 12

/// P23 slice 7: three threads of one project at once, as the app holds them, with every kind of end, and then nothing left behind.
/// Off by default; CI runs it with the other soak (`WORKBENCH_SOAK=1 swift test --filter ConcurrentSoakTests`).
@Suite(.serialized, .processGate, .enabled(if: soakEnabled)) struct ConcurrentSoakTests {
    private struct Scenario {
        var name: String
        var directives: [String]
        var expected: RunResult
        var timeout: TimeInterval = 30
        var killGrace: TimeInterval = 5
        /// Stop the turn from outside once it is up.
        var stopAfterReady = false
        var grandchild = false
    }

    private static let scenarios: [Scenario] = [
        Scenario(name: "ok", directives: ["stream-events=5"], expected: .succeeded),
        Scenario(name: "crash", directives: ["crash-after=1"], expected: .failed),
        Scenario(name: "killed", directives: ["die-after=2"], expected: .failed),
        Scenario(name: "hang", directives: ["hang-after=1"], expected: .timedOut, timeout: 0.7),
        Scenario(name: "stop", directives: ["hang-after=1"], expected: .stopped, stopAfterReady: true),
        // SIGTERM is ignored: the runner escalates to SIGKILL after its grace.
        Scenario(
            name: "ignore-term", directives: ["ignore-term", "hang-after=1"], expected: .stopped, killGrace: 1,
            stopAfterReady: true),
        Scenario(name: "pipe-holder", directives: ["delay-ms=120"], expected: .succeeded, grandchild: true),
        Scenario(name: "flood", directives: ["flood=2000000"], expected: .succeeded),
        Scenario(
            name: "leftover-child", directives: ["hang-after=1"], expected: .stopped, stopAfterReady: true, grandchild: true),
    ]

    private struct Outcome {
        var id: String
        var scenario: Scenario
        var report: TurnReport
        var grandchild: pid_t?
    }

    /// Whether this thread's check was not run because the slots were full (recorded as a failed check that says so).
    private static func refusedAtTheGate(_ fx: RunnerFixture, _ id: String) -> Bool {
        ((try? fx.events(id)) ?? []).contains {
            $0.kind == .checkRan && $0.data["error"]?.stringValue?.contains("max_concurrent_checks") == true
        }
    }

    private func config(_ fx: RunnerFixture) throws -> Config { try fx.loadedConfig() }

    /// One thread's turn, with what its scenario asks of the fake claude.
    private func run(_ fx: RunnerFixture, id: String, scenario: Scenario) async throws -> Outcome {
        var options = fx.options(timeout: scenario.timeout)
        options.killGrace = scenario.killGrace
        var directives = scenario.directives
        let ready = FakeClaude.scratch("ready")
        let pidFile = FakeClaude.scratch("gc.pid")
        defer { for path in [ready, pidFile] { try? FileManager.default.removeItem(atPath: path) } }
        if scenario.stopAfterReady { directives.append("ready=\(ready)") }
        if scenario.grandchild { directives.append("grandchild=\(pidFile)") }
        options.parentEnvironment["FAKE_CLAUDE"] = directives.joined(separator: ",")

        let runner = fx.runner(id)
        let report: TurnReport
        if scenario.stopAfterReady {
            let task = Task { try await runner.run(options) }
            try #require(await pollUntil { FileManager.default.fileExists(atPath: ready) }, "\(scenario.name): never ready")
            await runner.stop()
            report = try await task.value
        } else {
            report = try await runner.run(options)
        }
        var child: pid_t?
        if scenario.grandchild, let text = try? String(contentsOfFile: pidFile, encoding: .utf8) { child = pid_t(text) }
        return Outcome(id: id, scenario: scenario, report: report, grandchild: child)
    }

    @Test func threeThreadsAtOnceEachEndingItsOwnWayLeaveNothingBehind() async throws {
        let fx = try await RunnerFixture(extraConfig: "max_active_threads = 3")
        let config = try config(fx)
        let before = openDescriptorCount()
        var children: [pid_t] = []
        var counts: [String: Int] = [:]

        for round in 0..<soakRounds {
            let picked = (0..<3).map { Self.scenarios[(round * 3 + $0) % Self.scenarios.count] }
            var ids: [String] = []
            for index in 0..<3 { ids.append(try await fx.approvedThread("c\(round)x\(index)", config: config)) }
            #expect(Set(ids).count == 3)
            let active = ThreadStore(project: fx.project).activeThreadIDs().count
            #expect(active == 3, "round \(round): three threads are active at once")

            // All three at the same moment: three worktrees cut, three runners, three logs.
            let outcomes = try await withThrowingTaskGroup(of: Outcome.self) { group in
                for (id, scenario) in zip(ids, picked) { group.addTask { try await self.run(fx, id: id, scenario: scenario) } }
                var all: [Outcome] = []
                for try await outcome in group { all.append(outcome) }
                return all
            }

            for outcome in outcomes {
                let (id, scenario) = (outcome.id, outcome.scenario)
                let label = "\(scenario.name) in round \(round)"
                #expect(outcome.report.result == scenario.expected, "\(label): \(outcome.report.result)")
                counts[outcome.report.result.rawValue, default: 0] += 1
                let contents = try fx.contents(id)
                #expect(contents.isHealthy, "\(label): \(contents.problems)")
                #expect(contents.openTurn == nil, "\(label): a turn was left open")
                let started = contents.events.filter { $0.kind == .turnStarted }.count
                let ends = ended(contents.events)
                #expect(started == 1 && ends.count == 1, "\(label): \(started) started, \(ends.count) ended")
                #expect(fx.contentsOfRunnerFile(id) == nil, "\(label): runner.json left behind")
                if let child = outcome.grandchild { children.append(child) }
            }
            // No two threads shared a worktree: every thread has its own folder and branch.
            let worktrees = Set(ids.map { fx.project.worktreesDirectory.appendingPathComponent($0).path })
            #expect(worktrees.count == 3 && worktrees.allSatisfy { FileManager.default.fileExists(atPath: $0) })

            for id in ids { try await fx.service.abandon(id: id, force: true) }
            #expect(ThreadStore(project: fx.project).activeThreadIDs().isEmpty, "round \(round): the slots are free again")
        }

        for pid in children { #expect(await FakeClaude.waitUntilGone(pid), "a child (\(pid)) outlived its turn") }
        #expect(!(await processExists(commandLine: "sleep 300")), "a tool child is still running")
        let listing = GitRunner(executable: URL(fileURLWithPath: "/bin/ps"), environment: [:], timeout: 10)
        let ps = try await listing.run(["-axo", "command="], in: URL(fileURLWithPath: "/tmp"))
        let strays = ps.stdout.split(separator: "\n").filter { $0.hasPrefix(FakeClaude.executable.path) }
        #expect(strays.isEmpty, "a fake claude is still running: \(strays)")
        let after = openDescriptorCount()
        #expect(after - before <= 6, "descriptors grew from \(before) to \(after) over \(soakRounds) rounds of three")

        let list = try await fx.git.run(["worktree", "list", "--porcelain"], in: fx.repo)
        #expect(list.stdout.components(separatedBy: "worktree ").count == 2, "worktrees left behind:\n\(list.stdout)")
        let admin = fx.repo.appendingPathComponent(".git/worktrees")
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: admin.path)) ?? []).isEmpty, "worktree entries left")
        let locks = (try? FileManager.default.contentsOfDirectory(atPath: fx.repo.appendingPathComponent(".git").path)) ?? []
        #expect(!locks.contains { $0.hasSuffix(".lock") }, "a git lock file was left: \(locks)")
        print("CONCURRENT SOAK rounds=\(soakRounds) of 3 results=\(counts.sorted { $0.key < $1.key }) fds \(before)->\(after)")
    }

    @Test func checksNeverOverlapPastTheCapAndTheOneOverIsRefusedNotQueued() async throws {
        let script = try CheckScript()
        let log = script.path("overlap.log")
        let release = script.path("release")
        let body = [
            "echo \"start $PWD\" >> \"\(log)\"",
            "while [ ! -f \"\(release)\" ]; do sleep 0.05; done",
            "echo \"end $PWD\" >> \"\(log)\"",
        ].joined(separator: "\n")
        let check = try script.write(body, name: "wait-check.sh")
        let fx = try await RunnerFixture(
            extraConfig: "max_active_threads = 3\nmax_concurrent_checks = 2\ncheck_command = \"\(check)\"")
        let config = try config(fx)
        var ids: [String] = []
        for index in 0..<3 { ids.append(try await fx.approvedThread("k\(index)", config: config)) }

        // Each run ends as "ok", "refused:<max>" (the run was refused before any turn), or "error:<what>".
        let upFront = Flag()
        let jobs = ids.map { ($0, fx.runner($0)) }
        let options = fx.options()
        let runs = Task { () -> [String: String] in
            await withTaskGroup(of: (String, String).self) { group in
                for (id, runner) in jobs {
                    group.addTask {
                        do {
                            _ = try await runner.run(options)
                            return (id, "ok")
                        } catch RunnerError.tooManyChecks(_, let max) {
                            upFront.set()
                            return (id, "refused:\(max)")
                        } catch { return (id, "error:\(error)") }
                    }
                }
                var all: [String: String] = [:]
                for await (id, outcome) in group { all[id] = outcome }
                return all
            }
        }
        // Two checks are in; the third is refused the moment it asks (or its run was, before any turn), whichever came first.
        let started = await pollUntil {
            let text = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
            return text.components(separatedBy: "start ").count == 3
        }
        #expect(started, "two checks should have started")
        let refused = await pollUntil { upFront.isSet || ids.contains { Self.refusedAtTheGate(fx, $0) } }
        #expect(refused, "the third was refused, one way or the other")
        try "go\n".write(toFile: release, atomically: true, encoding: .utf8)
        let results = await runs.value

        var refusedRuns = 0
        for id in ids {
            let outcome = results[id] ?? "none"
            if outcome == "ok" {
                let contents = try fx.contents(id)
                #expect(contents.isHealthy && contents.openTurn == nil && contents.openCheck == nil)
                let started = contents.events.filter { $0.kind == .turnStarted }.count
                #expect(started == 1 && ended(contents.events).count == 1, "\(id): one end per start")
            } else if outcome == "refused:2" {
                refusedRuns += 1
                #expect(try fx.kinds(id).filter { $0 == "turn.started" }.isEmpty, "a run refused up front spent no turn")
            } else {
                Issue.record("\(id): \(outcome)")
            }
        }
        let gateRefusals = ids.filter { Self.refusedAtTheGate(fx, $0) }
        #expect(
            refusedRuns + gateRefusals.count == 1,
            "exactly one of three was refused: \(refusedRuns) up front, \(gateRefusals.count) at the gate")
        for id in gateRefusals {
            let ran = try #require(try fx.events(id).last { $0.kind == .checkRan })
            #expect(ran.data["result"]?.stringValue == "failed", "a refused check is a failed one, with its reason")
        }

        // The check command itself never ran more than twice at a time.
        var running = 0
        var peak = 0
        for line in ((try? String(contentsOfFile: log, encoding: .utf8)) ?? "").split(separator: "\n") {
            running += line.hasPrefix("start ") ? 1 : -1
            peak = max(peak, running)
        }
        #expect(peak <= 2 && running == 0, "checks overlapped \(peak) at once, \(running) still running at the end")
        #expect(!(await processExists(commandLine: "sleep 0.05")), "a check's child is still running")
    }

    @Test func aSyncAndTwoRunsShareTheRepositoryWithoutTrippingOverEachOther() async throws {
        let fx = try await RunnerFixture(extraConfig: "max_active_threads = 3")
        let config = try config(fx)
        _ = try await addOrigin(fx)
        let syncing = try await fx.service.newThread(name: "sync", base: "main", config: config)
        let manager = WorktreeManager(repoRoot: fx.repo, git: fx.git)
        let worktree = try await manager.create(threadID: syncing, base: "main").path
        try "one\nmine\n".write(to: worktree.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "theirs\n".write(to: fx.repo.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        _ = try await fx.git.run(["add", "-A"], in: fx.repo)
        _ = try await fx.git.run(["commit", "-q", "-m", "land b"], in: fx.repo)
        _ = try await fx.git.run(["push", "-q", "origin", "main"], in: fx.repo)
        let others = [try await fx.approvedThread("r1", config: config), try await fx.approvedThread("r2", config: config)]

        // The sync fetches and merges while two runs cut their own worktrees: all of them take the project's git lock in turn.
        async let merged = fx.service.syncBase(id: syncing)
        async let first = fx.runner(others[0]).run(fx.options())
        async let second = fx.runner(others[1]).run(fx.options())
        let (result, one, two) = try await (merged, first, second)

        guard case .merged(let moved, _, _) = result else {
            Issue.record("got \(result)")
            return
        }
        #expect(moved.behind == 1)
        #expect(one.result == .succeeded && two.result == .succeeded)
        for id in others {
            let contents = try fx.contents(id)
            #expect(contents.isHealthy && contents.openTurn == nil)
            #expect(ended(contents.events).count == 1)
        }
        #expect(try String(contentsOf: worktree.appendingPathComponent("b.txt"), encoding: .utf8) == "theirs\n")
        let locks = (try? FileManager.default.contentsOfDirectory(atPath: fx.repo.appendingPathComponent(".git").path)) ?? []
        #expect(!locks.contains { $0.hasSuffix(".lock") }, "a git lock file was left: \(locks)")
    }
}
