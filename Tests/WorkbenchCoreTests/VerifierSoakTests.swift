import Foundation
import Testing

@testable import WorkbenchCore

private let soakEnabled = ProcessInfo.processInfo.environment["WORKBENCH_SOAK"] == "1"
private let soakRuns = Int(ProcessInfo.processInfo.environment["WORKBENCH_SOAK_RUNS"] ?? "") ?? 100

/// The verifier under repetition: every ending, many times, on one thread. Every `verifier.started` has exactly one
/// `verifier.ended`, nothing it started outlives it, and nothing accumulates. Run by CI with the rest of the soak:
/// `WORKBENCH_SOAK=1 swift test --filter SoakTests`.
@Suite(.serialized, .enabled(if: soakEnabled)) struct VerifierSoakTests {
    private struct Scenario {
        var name: String
        var directives: [String]
        var ok: Bool
        var timeout: TimeInterval = 20
        var grace: TimeInterval = 2
        var stopAfterAttach = false
        var leavesChild = false
    }

    private static let scenarios: [Scenario] = [
        Scenario(name: "ok", directives: ["proof=shot.png"], ok: true),
        Scenario(name: "ok-slow", directives: ["delay-ms=50"], ok: true),
        Scenario(name: "crash", directives: ["crash-after=1"], ok: false),
        Scenario(name: "killed", directives: ["die-after=1"], ok: false),
        Scenario(name: "error", directives: ["error-result"], ok: false),
        Scenario(name: "budget", directives: ["budget-stop"], ok: false),
        Scenario(name: "hang", directives: ["hang-after=1"], ok: false, timeout: 0.7),
        Scenario(name: "ignores-term", directives: ["hang-after=1", "ignore-term"], ok: false, timeout: 0.7, grace: 0.3),
        Scenario(name: "stop", directives: ["hang-after=1"], ok: false, stopAfterAttach: true),
        Scenario(name: "grandchild", directives: ["grandchild=%PID%"], ok: true, leavesChild: true),
        Scenario(name: "detached", directives: ["detached=%PID%"], ok: true, leavesChild: true),
    ]

    @Test func manyVerifierRunsEachEndOnce() async throws {
        let v = try await VerifierFixture()
        let before = openDescriptorCount()
        var spawned: [pid_t] = []
        var results: [String: Int] = [:]

        for i in 0..<soakRuns {
            let scenario = Self.scenarios[i % Self.scenarios.count]
            var directives = scenario.directives
            var pidFile: String?
            if scenario.leavesChild {
                pidFile = FakeClaude.scratch("verifier-soak.pid")
                directives = directives.map { $0.replacingOccurrences(of: "%PID%", with: pidFile ?? "") }
            }
            let holder = SoakStop()
            let report: VerifierReport
            if scenario.stopAfterAttach {
                let task = Task {
                    try await v.fx.service.verifier(
                        id: v.id, config: v.config, again: true,
                        environment: v.environment(directives.joined(separator: ",")), timeout: scenario.timeout,
                        killGrace: scenario.grace, attach: { holder.attach($0) })
                }
                try #require(await holder.waitForRun(), "\(scenario.name) #\(i): never attached")
                holder.stop()
                report = try await task.value
            } else {
                report = try await v.fx.service.verifier(
                    id: v.id, config: v.config, again: true, environment: v.environment(directives.joined(separator: ",")),
                    timeout: scenario.timeout, killGrace: scenario.grace)
            }
            #expect(report.ok == scenario.ok, "\(scenario.name) #\(i): ok \(report.ok), reason \(report.reason ?? "-")")
            results[scenario.name, default: 0] += 1
            #expect(v.fx.contentsOfRunnerFile(v.id) == nil, "\(scenario.name) #\(i): runner.json left behind")
            if let pidFile, let text = try? String(contentsOfFile: pidFile, encoding: .utf8) {
                if let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) { spawned.append(pid) }
                try? FileManager.default.removeItem(atPath: pidFile)
            }
        }

        // The invariants over the whole log.
        let contents = try v.fx.contents(v.id)
        #expect(contents.isHealthy, "log not healthy: \(contents.problems)")
        let marks = try v.verifierEvents().map(\.kind.rawValue)
        #expect(marks == Array(repeating: ["verifier.started", "verifier.ended"], count: soakRuns).flatMap { $0 })

        for pid in spawned { #expect(await FakeClaude.waitUntilGone(pid), "a child \(pid) outlived its verifier") }
        #expect(!(await processExists(commandLine: "sleep 300")), "a tool child is still running")
        let listing = GitRunner(executable: URL(fileURLWithPath: "/bin/ps"), environment: [:], timeout: 10)
        let ps = try await listing.run(["-axo", "command="], in: URL(fileURLWithPath: "/tmp"))
        let strays = ps.stdout.split(separator: "\n").filter { $0.hasPrefix(FakeClaude.executable.path) }
        #expect(strays.isEmpty, "a fake claude is still running: \(strays)")
        let after = openDescriptorCount()
        #expect(after - before <= 4, "descriptors grew from \(before) to \(after) over \(soakRuns) runs")
        print("SOAK verifier runs=\(soakRuns) \(results.sorted { $0.key < $1.key }) fds \(before)->\(after)")
    }
}

private final class SoakStop: @unchecked Sendable {
    private let lock = NSLock()
    private var run: ProcessRun?
    private var stopRequested = false

    func attach(_ new: ProcessRun) {
        let stop = lock.withLock { () -> Bool in
            run = new
            return stopRequested
        }
        if stop { new.stop() }
    }

    func stop() {
        let current = lock.withLock { () -> ProcessRun? in
            stopRequested = true
            return run
        }
        current?.stop()
    }

    func waitForRun() async -> Bool {
        let deadline = Date().addingTimeInterval(Patience.limit)
        while Date() < deadline {
            if lock.withLock({ run != nil }) { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return false
    }
}
