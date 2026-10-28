import Foundation
import Testing

@testable import WorkbenchCore

private func list(_ pairs: [(String, String)]) -> String {
    "[" + pairs.map { "{\"name\": \"\($0.0)\", \"bucket\": \"\($0.1)\"}" }.joined(separator: ",") + "]"
}

private func shipped(_ fx: RunnerFixture, _ gh: FakeGH) async throws -> String {
    let (id, _) = try await acceptedThread(fx)
    _ = try await addOrigin(fx)
    _ = try await fx.service.shipPush(id: id, gh: gh.runner)
    _ = try await fx.service.shipOpenPR(id: id, gh: gh.runner)
    return id
}

@Suite(.processGate) struct ShipChecksTests {
    @Test func oneReadOfTheRecordedPullRequestsChecksFromTheProjectRootWithGHRepoDropped() async throws {
        let fx = try await RunnerFixture()
        let gh = try FakeGH(in: fx)
        let id = try await shipped(fx, gh)
        try gh.put("checks_last", list([("test", "pass"), ("lint", "skipping")]))
        let summary = try await fx.service.prChecks(id: id, gh: gh.runner)
        #expect(summary.state == .passed && summary.checks.map(\.name) == ["test", "lint"])
        #expect(gh.calls.filter { $0.hasPrefix("pr checks") } == ["pr checks 12 --json name,bucket"])
        #expect(gh.read("repo")?.trimmingCharacters(in: .whitespacesAndNewlines) == "unset")
    }

    @Test func pendingAndFailingListsAreReturnedEvenThoughGhExitsNonZero() async throws {
        let fx = try await RunnerFixture()
        let gh = try FakeGH(in: fx)
        let id = try await shipped(fx, gh)
        try gh.put("checks_last", list([("test", "pending"), ("lint", "fail")]))
        #expect(try await fx.service.prChecks(id: id, gh: gh.runner).state == .pending)
        try gh.put("checks_last", list([("test", "pass"), ("lint", "fail")]))
        #expect(try await fx.service.prChecks(id: id, gh: gh.runner).state == .failed)
    }

    @Test func aCancelledCheckReadsFailedNeverPassed() async throws {
        let fx = try await RunnerFixture()
        let gh = try FakeGH(in: fx)
        let id = try await shipped(fx, gh)
        try gh.put("checks_last", list([("test", "pass"), ("app", "cancel")]))
        #expect(try await fx.service.prChecks(id: id, gh: gh.runner).state == .failed)
    }

    @Test func noChecksReportedIsNoneNotAnError() async throws {
        let fx = try await RunnerFixture()
        let gh = try FakeGH(in: fx)
        let id = try await shipped(fx, gh)
        // The fake says "no checks reported" on stderr, exit 1, when it has no list.
        #expect(try await fx.service.prChecks(id: id, gh: gh.runner).state == .none)
    }

    @Test func aThreadWithNoRecordedPullRequestIsNotShipped() async throws {
        let fx = try await RunnerFixture()
        let gh = try FakeGH(in: fx)
        let (id, _) = try await acceptedThread(fx)
        await #expect(throws: ShipError.notShipped) { try await fx.service.prChecks(id: id, gh: gh.runner) }
        #expect(gh.count("pr checks") == 0)
    }

    @Test func aMissingGhAndABadIdAreRefusedBeforeAnythingRuns() async throws {
        let fx = try await RunnerFixture()
        let gh = try FakeGH(in: fx)
        let id = try await shipped(fx, gh)
        await #expect(throws: ShipError.ghMissing) { try await fx.service.prChecks(id: id, gh: nil) }
        await #expect(throws: ShipError.invalidName("../x")) { try await fx.service.prChecks(id: "../x", gh: gh.runner) }
    }

    @Test func aBrokenAnswerAndAHangAreErrorsNotAGreenList() async throws {
        let fx = try await RunnerFixture()
        let gh = try FakeGH(in: fx)
        let id = try await shipped(fx, gh)
        try gh.put("checks_fail", "")
        await #expect(throws: ShipError.self) { try await fx.service.prChecks(id: id, gh: gh.runner) }
        try? FileManager.default.removeItem(at: gh.dir.appendingPathComponent("checks_fail"))
        try gh.put("checks_hang", "")
        await #expect(throws: ShipError.self) { try await fx.service.prChecks(id: id, gh: gh.runner, callTimeout: 1) }
    }

    @Test func itWritesNothingToTheLog() async throws {
        let fx = try await RunnerFixture()
        let gh = try FakeGH(in: fx)
        let id = try await shipped(fx, gh)
        try gh.put("checks_last", list([("test", "pass")]))
        let before = try fx.events(id).count
        _ = try await fx.service.prChecks(id: id, gh: gh.runner)
        #expect(try fx.events(id).count == before)
    }
}
