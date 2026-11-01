import Foundation
import Testing

@testable import WorkbenchCore

@Suite(.processGate) struct TaskPendingTests {
    private let units = #"echo '[{"id":"ROU"},{"id":"TUR"},{"id":"PAN"}]'"#

    private func fixture(_ script: String? = nil) throws -> TaskFixture {
        let fx = try TaskFixture(front: "fix: pr\nbatch: 1\npending: pending.sh")
        try fx.script(script ?? units)
        return fx
    }

    @Test func anApprovedTasksUnitsAreCountedWithoutTheBatchLimit() async throws {
        let fx = try fixture()
        try await fx.library.approve(fx.name)
        let count = await TaskPending.count(name: fx.name, project: fx.project, gh: nil)
        #expect(count == .count(waiting: 3, listed: 3))
        #expect(count.text == "3 of 3")
    }

    @Test func unitsAPastRunTookAreLeftOutAsARunWouldLeaveThemOut() async throws {
        let fx = try fixture()
        try await fx.library.approve(fx.name)
        let writer = try await fx.log.openWriter()
        try await writer.append(.taskRunStarted, data: ["trigger": "tick"])
        try await writer.append(.taskRunThread, data: ["thread": "bump-rou", "units": ["ROU"], "hash": "h"])
        try await writer.append(.taskRunEnded, data: ["outcome": "pr-opened", "units": ["ROU"], "thread": "bump-rou"])
        await writer.close()
        // GitHub cannot be asked (no gh): a unit with a thread stays out, as a run would keep it out.
        let count = await TaskPending.count(name: fx.name, project: fx.project, gh: nil)
        #expect(count == .count(waiting: 2, listed: 3))
    }

    @Test func aTaskThatIsNotApprovedOrWasEditedIsNotRun() async throws {
        let marker = try Scratch.directory("marker").appendingPathComponent("ran")
        let fx = try fixture(#"touch '\#(marker.path)'; "# + units)
        let never = await TaskPending.count(name: fx.name, project: fx.project, gh: nil)
        #expect(never == .notRun(why: "not approved") && !FileManager.default.fileExists(atPath: marker.path))
        try await fx.library.approve(fx.name)
        try fx.script(#"touch '\#(marker.path)'; echo '[]'"#)
        let stale = await TaskPending.count(name: fx.name, project: fx.project, gh: nil)
        #expect(stale == .notRun(why: "edited since it was approved"))
        #expect(!FileManager.default.fileExists(atPath: marker.path), "the edited script was never executed")
    }

    @Test func aTaskWithoutAListAndAScriptThatFailsAreSaidPlainly() async throws {
        let plain = try TaskFixture(front: "fix: report")
        try await plain.library.approve(plain.name)
        #expect(await TaskPending.count(name: plain.name, project: plain.project, gh: nil) == .noScript)
        let broken = try fixture("echo oops >&2; exit 3")
        try await broken.library.approve(broken.name)
        let count = await TaskPending.count(name: broken.name, project: broken.project, gh: nil)
        guard case .failed(let why) = count else { Issue.record("expected failed: \(count)"); return }
        #expect(why.contains("exited with 3") && count.text.hasPrefix("unknown ("))
    }
}
