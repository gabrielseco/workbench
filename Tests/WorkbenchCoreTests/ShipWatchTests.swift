import Foundation
import Testing

@testable import WorkbenchCore

private func checks(_ pairs: [(String, String)]) -> String {
    "[" + pairs.map { "{\"name\": \"\($0.0)\", \"bucket\": \"\($0.1)\"}" }.joined(separator: ",") + "]"
}

/// A thread that is shipped through the fake `gh`, ready to watch.
private func shippedThread(_ fx: RunnerFixture, _ gh: FakeGH) async throws -> String {
    let (id, _) = try await acceptedThread(fx)
    _ = try await addOrigin(fx)
    _ = try await fx.service.shipPush(id: id, gh: gh.runner)
    _ = try await fx.service.shipOpenPR(id: id, gh: gh.runner)
    return id
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var elapsed: TimeInterval = 0
    func advance(_ seconds: TimeInterval) { lock.withLock { elapsed += seconds } }
    var now: Date { lock.withLock { Date(timeIntervalSince1970: 1_000_000 + elapsed) } }
}

private final class Changes: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [PRChecksSummary] = []
    func add(_ s: PRChecksSummary) { lock.withLock { items.append(s) } }
    var all: [PRChecksSummary] { lock.withLock { items } }
}

private func watch(
    _ fx: RunnerFixture, _ gh: FakeGH, id: String, timeout: TimeInterval = 1_800, callTimeout: TimeInterval = 10,
    changes: Changes = Changes(), clock: Clock = Clock()
) async throws -> ShipWatchResult {
    try await fx.service.watchPR(
        id: id, gh: gh.runner, interval: 15, timeout: timeout, callTimeout: callTimeout,
        now: { clock.now }, sleep: { clock.advance($0) }, onChange: { changes.add($0) })
}

@Suite struct ShipWatchTests {
    @Test func bucketsAreSummarisedAndOddInputIsAnErrorNotNone() throws {
        func state(_ pairs: [(String, String)]) throws -> PRChecksSummary.State {
            try PRChecksSummary.parse(checks(pairs)).state
        }
        #expect(try state([("a", "pass"), ("b", "skipping")]) == .passed)
        #expect(try state([("a", "pass"), ("b", "fail")]) == .failed)
        #expect(try state([("a", "cancel")]) == .failed)
        #expect(try state([("a", "pass"), ("b", "pending")]) == .pending)
        #expect(try state([("a", "fail"), ("b", "pending")]) == .pending, "wait for the rest before ending")
        #expect(try state([]) == .none)
        for bad in ["", "not json", "{}", "[1]", "[{\"name\": \"a\"}]", checks([("a", "bogus")])] {
            #expect(throws: ShipError.self) { try PRChecksSummary.parse(bad) }
        }
    }

    @Test func pollsUntilNothingIsPendingAndReportsEachChangeOnce() async throws {
        let fx = try await RunnerFixture()
        let gh = try FakeGH(in: fx)
        let id = try await shippedThread(fx, gh)
        try gh.put("checks_1", checks([("build", "pending"), ("lint", "pass")]))
        try gh.put("checks_2", checks([("build", "pending"), ("lint", "pass")]))
        try gh.put("checks_3", checks([("build", "pass"), ("lint", "pass")]))

        let changes = Changes()
        let result = try await watch(fx, gh, id: id, changes: changes)
        guard case .passed(let list) = result else {
            Issue.record("got \(result)")
            return
        }
        #expect(list.map(\.name).sorted() == ["build", "lint"])
        #expect(changes.all.count == 2, "pending once, then passed: not once per poll")
        #expect(gh.calls.filter { $0.hasPrefix("pr checks") }.count == 3)
    }

    @Test func aFailureEndsTheWatchOnceNothingIsRunning() async throws {
        let fx = try await RunnerFixture()
        let gh = try FakeGH(in: fx)
        let id = try await shippedThread(fx, gh)
        try gh.put("checks_1", checks([("build", "fail"), ("e2e", "pending")]))
        try gh.put("checks_2", checks([("build", "fail"), ("e2e", "cancel")]))
        let result = try await watch(fx, gh, id: id)
        guard case .failed(let list) = result else {
            Issue.record("got \(result)")
            return
        }
        #expect(list.count == 2)
        #expect(gh.calls.filter { $0.hasPrefix("pr checks") }.count == 2)
    }

    @Test func itChangesNothingAndOnlyAsksForChecksByNumberWithGHRepoDropped() async throws {
        let fx = try await RunnerFixture()
        let gh = try FakeGH(in: fx)
        let id = try await shippedThread(fx, gh)
        try gh.put("checks_last", checks([("build", "pass")]))
        let log = fx.project.eventsURL(id)
        let before = try Data(contentsOf: log)
        let callsBefore = gh.calls.count
        let withRepo = FakeGHRunner.with(gh, extra: ["GH_REPO": "evil/repo"])
        // The worktree is gone; the watch must not need it.
        try FileManager.default.removeItem(at: fx.project.worktreesDirectory.appendingPathComponent(id))

        let result = try await fx.service.watchPR(
            id: id, gh: withRepo, interval: 1, timeout: 60, now: { Date() }, sleep: { _ in }, onChange: { _ in })
        #expect(result == .passed([PRCheck(name: "build", bucket: "pass")]))
        #expect(try Data(contentsOf: log) == before, "the log is byte-identical")
        let added = Array(gh.calls.dropFirst(callsBefore))
        #expect(added == ["pr checks 12 --json name,bucket"], "\(added)")
        #expect(gh.read("repo")?.trimmingCharacters(in: .whitespacesAndNewlines) == "unset")
    }

    @Test func stillPendingAtTheLimitAndNoChecksAreNotSuccess() async throws {
        let fx = try await RunnerFixture()
        let gh = try FakeGH(in: fx)
        let id = try await shippedThread(fx, gh)

        try gh.put("checks_last", checks([("build", "pending")]))
        let slow = try await watch(fx, gh, id: id, timeout: 60)
        guard case .timedOut = slow else {
            Issue.record("got \(slow)")
            return
        }

        try FileManager.default.removeItem(at: gh.dir.appendingPathComponent("checks_last"))
        try FileManager.default.removeItem(at: gh.dir.appendingPathComponent("checks_n"))
        let none = try await watch(fx, gh, id: id)
        #expect(none == .noChecks)
    }

    @Test func repeatedFailuresAndAHungGHEndTheWatchAndLeaveNoProcess() async throws {
        let fx = try await RunnerFixture()
        let gh = try FakeGH(in: fx)
        let id = try await shippedThread(fx, gh)

        try gh.put("checks_fail", "")
        do {
            _ = try await watch(fx, gh, id: id)
            Issue.record("expected an error")
        } catch let error as ShipError {
            guard case .ghFailed = error else {
            Issue.record("got \(error)")
            return
        }
        }
        #expect(gh.calls.filter { $0.hasPrefix("pr checks") }.count == ThreadService.watchFailureLimit)

        try FileManager.default.removeItem(at: gh.dir.appendingPathComponent("checks_fail"))
        try gh.put("checks_hang", "")
        let started = Date()
        do {
            _ = try await watch(fx, gh, id: id, callTimeout: 1)
            Issue.record("expected an error")
        } catch let error as ShipError {
            guard case .gitFailed(let why) = error else {
            Issue.record("got \(error)")
            return
        }
            #expect(why.contains("did not answer"), "\(why)")
        }
        #expect(Date().timeIntervalSince(started) < 30)
        let written = gh.read("checks_pid") ?? ""
        let pid = Int32(written.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(pid != nil)
        if let pid {
            try await Task.sleep(nanoseconds: 300_000_000)
            #expect(kill(pid, 0) != 0, "no `gh` is left behind")
        }
    }

    @Test func theLimitIsCheckedBeforeAskingAgainAndTheSleepIsCutToWhatIsLeft() async throws {
        let fx = try await RunnerFixture()
        let gh = try FakeGH(in: fx)
        let id = try await shippedThread(fx, gh)
        try gh.put("checks_1", checks([("build", "pending")]))
        try gh.put("checks_2", checks([("build", "pass")]))
        let clock = Clock()
        let result = try await fx.service.watchPR(
            id: id, gh: gh.runner, interval: 300, timeout: 60, callTimeout: 10,
            now: { clock.now }, sleep: { clock.advance($0) }, onChange: { _ in })
        // One poll, then a sleep of the 60 s that were left, then the limit: the later pass is not waited for.
        guard case .timedOut = result else {
            Issue.record("got \(result)")
            return
        }
        #expect(clock.now.timeIntervalSince1970 - 1_000_000 <= 60)
        #expect(gh.calls.filter { $0.hasPrefix("pr checks") }.count == 1)
    }

    @Test func aBadPollAtTheDeadlineReportsTheLastGoodStateAsTimedOut() async throws {
        let fx = try await RunnerFixture()
        let gh = try FakeGH(in: fx)
        let id = try await shippedThread(fx, gh)
        try gh.put("checks_1", checks([("build", "pending")]))
        try gh.put("checks_hang_from", "2")
        // Every reading of the clock is 17 s later, so the limit passes during the second, hung poll.
        let ticks = Clock()
        let result = try await fx.service.watchPR(
            id: id, gh: gh.runner, interval: 1, timeout: 60, callTimeout: 1,
            now: {
                ticks.advance(17)
                return ticks.now
            },
            sleep: { _ in }, onChange: { _ in })
        #expect(result == .timedOut([PRCheck(name: "build", bucket: "pending")]))
    }

    @Test func repeatedMalformedAnswersEndWithAnErrorNotAsPending() async throws {
        let fx = try await RunnerFixture()
        let gh = try FakeGH(in: fx)
        let id = try await shippedThread(fx, gh)
        try gh.put("checks_last", checks([("build", "bogus")]))
        do {
            _ = try await watch(fx, gh, id: id)
            Issue.record("expected an error")
        } catch let error as ShipError {
            guard case .ghFailed = error else {
                Issue.record("got \(error)")
                return
            }
        }
        #expect(gh.calls.filter { $0.hasPrefix("pr checks") }.count == ThreadService.watchFailureLimit)
    }

    @Test func aThreadWithoutARecordedPRIsRefusedWithTheFix() async throws {
        let fx = try await RunnerFixture()
        let gh = try FakeGH(in: fx)
        let (id, _) = try await acceptedThread(fx)
        do {
            _ = try await watch(fx, gh, id: id)
            Issue.record("expected a refusal")
        } catch let error as ShipError {
            #expect(error == .notShipped)
            #expect(error.description.contains("workbench ship"))
        }
    }
}

enum FakeGHRunner {
    /// The same fake `gh` with extra environment, to check what the watch strips.
    static func with(_ gh: FakeGH, extra: [String: String]) -> GitRunner {
        GitRunner(
            executable: gh.runner.executable, environment: gh.runner.environment.merging(extra) { $1 }, timeout: 10)
    }
}
