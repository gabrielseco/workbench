import Foundation
import Testing

@testable import WorkbenchCore

/// A log is megabytes of `claude` lines, so a command that replays it twice pays twice. These count replays
/// instead of timing them: the count does not depend on the machine.
@Suite(.processGate) struct LogReadCountTests {
    private func ranThread(_ fx: RunnerFixture) async throws -> String {
        let id = try await fx.approvedThread()
        _ = try await fx.runner(id).run(fx.options())
        let worktree = fx.project.worktreesDirectory.appendingPathComponent(id)
        try "one\nhello\n".write(to: worktree.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        return id
    }

    @Test func reviewReplaysTheThreadLogOnce() async throws {
        let fx = try await RunnerFixture()
        let id = try await ranThread(fx)
        let url = fx.project.eventsURL(id)
        let before = EventLogReadCount.reads(of: url)
        _ = await ReviewLoader(project: fx.project, git: fx.git).load(id: id)
        #expect(EventLogReadCount.reads(of: url) - before == 1)
    }

    @Test func acceptPlanReplaysTheThreadLogOnce() async throws {
        let fx = try await RunnerFixture()
        let id = try await ranThread(fx)
        let url = fx.project.eventsURL(id)
        let before = EventLogReadCount.reads(of: url)
        _ = try await fx.service.acceptPlan(id: id)
        #expect(EventLogReadCount.reads(of: url) - before == 1)
    }

    @Test func acceptReplaysTheThreadLogAtMostThreeTimes() async throws {
        let fx = try await RunnerFixture()
        let id = try await ranThread(fx)
        let url = fx.project.eventsURL(id)
        let plan = try await fx.service.acceptPlan(id: id)
        let before = EventLogReadCount.reads(of: url)
        _ = try await fx.service.accept(id: id, shown: plan)
        let reads = EventLogReadCount.reads(of: url) - before
        #expect(reads <= 3)
    }
}
