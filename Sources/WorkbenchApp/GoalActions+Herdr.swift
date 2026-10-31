import Foundation
import WorkbenchCore

extension GoalActions {
    /// What "Open in Herdr" opened: the thread's worktree, or the project because the worktree is gone.
    struct HerdrOpenAnswer: Equatable, Sendable {
        var opened: HerdrOpened
        var projectInstead: Bool
    }

    /// A thread whose worktree is gone (shipped, accepted, discarded) opens the project's own checkout instead, with nothing typed
    /// into it: a session there can still pick up the pull request, for example to resolve its conflicts.
    static func openInHerdr(_ project: Project, _ thread: String, opener: HerdrOpener) async throws -> HerdrOpenAnswer {
        let folder: URL
        do { folder = try Editor.worktree(project: project, threadID: thread) } catch EditorError.noWorktree {
            let opened = try await opener.open(folder: project.root, label: project.root.lastPathComponent)
            return HerdrOpenAnswer(opened: opened, projectInstead: true)
        }
        return HerdrOpenAnswer(opened: try await opener.open(folder: folder, label: thread), projectInstead: false)
    }
}
