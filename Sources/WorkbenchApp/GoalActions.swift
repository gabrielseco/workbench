import AppKit
import Foundation
import WorkbenchCore

/// What the Goal screen's buttons do, as core does it. Seams so a test can see the order and the refusals without a repository.
struct GoalActions: Sendable {
    var approve: @Sendable (Project, String) async throws -> Void
    var run: @Sendable (Project, String) async throws -> Void
    var newThread: @Sendable (Project, String) async throws -> Void
    var openGoal: @Sendable (Project, String) async throws -> Void

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
        },
        openGoal: { project, thread in try await openInEditor(project, thread) })

    /// The goal file in the project's (else the global) `editor`, as `workbench open --goal` does; with none set, in the
    /// default app for the file rather than a refusal.
    static func openInEditor(_ project: Project, _ thread: String) async throws {
        let path = try Editor.goalFile(project: project, threadID: thread)
        let environment = ProcessInfo.processInfo.environment
        var editor: String?
        do { editor = try Config.load(from: project.configURL).editor } catch let error as ConfigError {
            guard error.problems.map(\.code) == [.notFound] else { throw error }
        }
        if editor == nil {
            editor = try GlobalConfig.load(from: GlobalConfig.defaultURL(environment: environment)).editor
        }
        guard let editor else {
            guard await MainActor.run(body: { NSWorkspace.shared.open(path) }) else {
                throw EditorError.launchFailed(editor: "the default app", reason: "it did not open \(path.path)")
            }
            return
        }
        let command = try Editor.command(
            for: editor, path: path.path, searchPath: environment["PATH"], isMacOS: Editor.isMacOS)
        try await EditorLauncher.launch(
            command, editor: editor, in: path.deletingLastPathComponent(), environment: Editor.environment(from: environment))
    }
}
