import Foundation
import Testing

@testable import WorkbenchCore

private let head = String(repeating: "a", count: 40)

private func view(_ state: String, head: String = head) -> String { "{\"state\": \"\(state)\", \"headRefOid\": \"\(head)\"}" }

private func checks(_ pairs: [(String, String)]) -> String {
    "[" + pairs.map { "{\"name\": \"\($0.0)\", \"bucket\": \"\($0.1)\"}" }.joined(separator: ",") + "]"
}

private func shipped(_ fx: RunnerFixture, _ gh: FakeGH) async throws -> String {
    let (id, _) = try await acceptedThread(fx)
    _ = try await addOrigin(fx)
    _ = try await fx.service.shipPush(id: id, gh: gh.runner)
    _ = try await fx.service.shipOpenPR(id: id, gh: gh.runner)
    return id
}

@Suite(.processGate) struct ShipMergeTests {
    @Test func statusReadsTheStateTheHeadAndTheChecksOfTheRecordedPullRequest() async throws {
        let fx = try await RunnerFixture()
        let gh = try FakeGH(in: fx)
        let id = try await shipped(fx, gh)
        try gh.put("view", view("OPEN"))
        try gh.put("checks_last", checks([("test", "pending"), ("lint", "pass")]))
        let status = try await fx.service.prStatus(id: id, gh: gh.runner)
        #expect(status.number == 12 && status.state == .open && status.head == head)
        #expect(status.checks?.state == .pending && !status.canMerge && status.mergeBlocker != nil)
        #expect(gh.calls.contains("pr view 12 --json state,headRefOid"))
    }

    @Test func checksThatCannotBeReadAreAnErrorOnTheStatusNeverGreen() async throws {
        let fx = try await RunnerFixture()
        let gh = try FakeGH(in: fx)
        let id = try await shipped(fx, gh)
        try gh.put("view", view("OPEN"))
        try gh.put("checks_fail", "")
        let status = try await fx.service.prStatus(id: id, gh: gh.runner)
        #expect(status.checks == nil && status.checksError != nil && !status.canMerge)
    }

    @Test func aStateThatCannotBeReadThrows() async throws {
        let fx = try await RunnerFixture()
        let gh = try FakeGH(in: fx)
        let id = try await shipped(fx, gh)
        try gh.put("view_fail", "")
        await #expect(throws: ShipError.self) { try await fx.service.prStatus(id: id, gh: gh.runner) }
    }

    @Test func greenCIMergesAtTheShownHeadAndReadsTheMergedState() async throws {
        let fx = try await RunnerFixture()
        let gh = try FakeGH(in: fx)
        let id = try await shipped(fx, gh)
        try gh.put("view", view("OPEN"))
        try gh.put("view_after_merge", view("MERGED"))
        try gh.put("checks_last", checks([("test", "pass")]))
        let after = try await fx.service.mergePR(id: id, gh: gh.runner, head: head)
        #expect(after.state == .merged)
        #expect(gh.calls.contains("pr merge 12 --squash --match-head-commit \(head)"))
    }

    @Test func nothingIsMergedWhileCIIsNotGreenOrTheHeadMoved() async throws {
        let fx = try await RunnerFixture()
        let gh = try FakeGH(in: fx)
        let id = try await shipped(fx, gh)
        try gh.put("view", view("OPEN"))
        try gh.put("checks_last", checks([("test", "fail")]))
        await #expect(throws: PRMergeError.self) { try await fx.service.mergePR(id: id, gh: gh.runner, head: head) }
        try gh.put("checks_last", checks([("test", "pass")]))
        try gh.put("view", view("OPEN", head: String(repeating: "b", count: 40)))
        await #expect(throws: PRMergeError.self) { try await fx.service.mergePR(id: id, gh: gh.runner, head: head) }
        #expect(gh.count("pr merge") == 0)
    }

    @Test func aRefusedMergeOrOneGitHubDoesNotCallMergedIsAnError() async throws {
        let fx = try await RunnerFixture()
        let gh = try FakeGH(in: fx)
        let id = try await shipped(fx, gh)
        try gh.put("view", view("OPEN"))
        try gh.put("checks_last", checks([("test", "pass")]))
        try gh.put("merge_fail", "base branch policy prohibits the merge")
        await #expect(throws: PRMergeError.refused("base branch policy prohibits the merge")) {
            try await fx.service.mergePR(id: id, gh: gh.runner, head: head)
        }
        try FileManager.default.removeItem(at: gh.dir.appendingPathComponent("merge_fail"))
        await #expect(throws: PRMergeError.notMerged(.open)) {
            try await fx.service.mergePR(id: id, gh: gh.runner, head: head)
        }
    }

    @Test func whyMergeIsNotOfferedCoversEveryState() {
        func status(_ state: PRState, _ checks: PRChecksSummary?, error: String? = nil) -> PRStatus {
            PRStatus(number: 1, state: state, head: head, checks: checks, checksError: error)
        }
        let passed = PRChecksSummary(checks: [PRCheck(name: "t", bucket: "pass")])
        #expect(status(.open, passed).canMerge && status(.open, passed).mergeBlocker == nil)
        #expect(!status(.open, passed, error: "boom").canMerge)
        #expect(!status(.open, PRChecksSummary(checks: [])).canMerge)
        #expect(!status(.open, nil).canMerge)
        #expect(!status(.merged, passed).canMerge && !status(.closed, passed).canMerge)
        #expect(!status(.open, PRChecksSummary(checks: [PRCheck(name: "t", bucket: "pending")])).canMerge)
    }
}
