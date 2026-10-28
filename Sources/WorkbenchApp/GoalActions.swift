import Foundation
import WorkbenchCore

/// What the Goal screen's buttons do, as core does it. Seams so a test can see the order and the refusals without a repository.
struct GoalActions: Sendable {
    var approve: @Sendable (Project, String) async throws -> Void
    var run: @Sendable (Project, String) async throws -> Void
    var newThread: @Sendable (Project, String) async throws -> Void

    static let core = GoalActions(
        approve: { project, thread in
            let git = try GitRunner.discover()
            try await ThreadService(project: project, git: git).approve(id: thread)
        },
        run: { project, thread in
            let git = try GitRunner.discover()
            _ = try await ThreadRunner(project: project, threadID: thread, git: git).run()
        },
        newThread: { project, name in
            let git = try GitRunner.discover()
            _ = try await ThreadService(project: project, git: git).newThread(name: name)
        })
}
