import Foundation
import WorkbenchCore

/// The chat's two live actions (P22 slice 6c), as `workbench chat` and `workbench goal draft --from-chat` call core.
extension GoalActions {
    /// Says one message in a chat (a new thread or an existing one) and waits for the turn to end; `DraftStop` ends the agent early.
    typealias Chat = @Sendable (Project, ChatTarget, String, DraftStop) async throws -> ChatResult
    /// Has the goal agent draft a goal from a chat's conversation, written into that same thread.
    typealias DraftFromChat = @Sendable (Project, String, DraftStop) async throws -> GoalDraftResult

    /// The project's config, nil when there is none; one that is there but broken is its own error, not "no goal agent".
    static func loadConfigIfPresent(_ project: Project) throws -> Config? {
        FileManager.default.fileExists(atPath: project.configURL.path) ? try Config.load(from: project.configURL) : nil
    }

    static let chatThroughCore: Chat = { project, target, message, stop in
        let git = try GitRunner.discover()
        // Never abandons another thread unasked: core's refusal names the one that is open.
        return try await ThreadService(project: project, git: git).chat(
            target: target, message: message, config: try loadConfigIfPresent(project), abandonActive: false,
            attach: { stop.attach($0) })
    }

    static let draftFromChatThroughCore: DraftFromChat = { project, thread, stop in
        let git = try GitRunner.discover()
        return try await ThreadService(project: project, git: git).draftGoal(
            target: .fromChat(id: thread, base: nil), request: "", config: try loadConfigIfPresent(project),
            attach: { stop.attach($0) })
    }
}
