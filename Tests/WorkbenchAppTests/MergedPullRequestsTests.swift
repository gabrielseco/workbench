import Foundation
import Testing
import WorkbenchCore

@testable import WorkbenchApp

/// The merges kept on disk: bounded, and only merges.
@Suite struct MergedPullRequestsTests {
    private func project() throws -> Project {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("merged-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return Project(root: root)
    }

    private func status(_ state: PRState) -> PRStatus {
        PRStatus(number: 7, state: state, head: String(repeating: "a", count: 40), checks: nil)
    }

    @Test func onlyAMergeIsKeptAndItComesBack() throws {
        let project = try project()
        defer { try? FileManager.default.removeItem(at: project.root) }
        MergedPullRequests.remember(status(.open), thread: "open", in: project)
        MergedPullRequests.remember(status(.closed), thread: "closed", in: project)
        MergedPullRequests.remember(status(.merged), thread: "merged", in: project)
        #expect(MergedPullRequests.load(project).keys.sorted() == ["merged"])
        #expect(MergedPullRequests.load(project)["merged"]?.state == .merged)
    }

    @Test func aFileOverTheLimitIsRefusedNotHeld() throws {
        let project = try project()
        defer { try? FileManager.default.removeItem(at: project.root) }
        try FileManager.default.createDirectory(at: project.workbenchDirectory, withIntermediateDirectories: true)
        try Data(repeating: 32, count: MergedPullRequests.maxBytes + 1).write(to: MergedPullRequests.url(project))
        #expect(MergedPullRequests.load(project).isEmpty)
    }
}
