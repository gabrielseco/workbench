import Foundation
import Testing

@testable import WorkbenchCore

@Suite(.processGate) struct AcceptGitCallsTests {
    @Test func theAcceptPlanAsksGitEachQuestionOnceAndInFewProcesses() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        _ = try await fx.runner(id).run(fx.options())
        let worktree = fx.project.worktreesDirectory.appendingPathComponent(id)
        try "one\nhello\n".write(to: worktree.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "x\n".write(to: worktree.appendingPathComponent("loose.txt"), atomically: true, encoding: .utf8)

        let counting = try await CountingGit(wrapping: fx.git)
        let plan = try await ThreadService(project: fx.project, git: counting.runner).acceptPlan(id: id)

        #expect(plan.hasPendingChanges)
        guard case .summary(let shown) = plan.diff else { Issue.record("no diff: \(plan.diff)"); return }
        #expect(shown.files.map(\.path).sorted() == ["a.txt", "loose.txt"])
        let calls = counting.calls
        #expect(Set(calls).count == calls.count, "a git command ran twice: \(calls.joined(separator: "\n"))")
        #expect(calls.count <= 10, "\(calls.count) git processes: \(calls.joined(separator: "\n"))")
    }
}
