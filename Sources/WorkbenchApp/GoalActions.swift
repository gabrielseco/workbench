import AppKit
import Foundation
import WorkbenchCore

/// A run this app started: `run` ends when the turn does, `stop` asks it to end (it still records a `stopped`).
struct RunHandle: Sendable {
    var run: @Sendable () async throws -> Void
    var stop: @Sendable () async -> Void
}

/// What the screens' buttons do, as core does it. Seams so a test can see the order and the refusals without a repository.
struct GoalActions: Sendable {
    var approve: @Sendable (Project, String) async throws -> Void
    var makeRun: @Sendable (Project, String, RunOptions) throws -> RunHandle
    var newThread: @Sendable (Project, String) async throws -> Void
    var openGoal: @Sendable (Project, String) async throws -> Void
    /// Asks the process that holds the thread (a terminal's `workbench run`) to stop; false when nothing holds it.
    var requestStop: @Sendable (Project, String) async -> Bool
    var openWorktree: @Sendable (Project, String) async throws -> Void
    var loadReview: @Sendable (Project, String) async -> ReviewReport?
    var acceptPlan: @Sendable (Project, String) async throws -> AcceptPlan
    var accept: @Sendable (Project, String, AcceptPlan, String?) async throws -> AcceptResult
    var discardPlan: @Sendable (Project, String) async throws -> DiscardPlan
    var discard: @Sendable (Project, String, DiscardPlan) async throws -> Void
    var patch: @Sendable (Project, String, String) async throws -> FilePatch?

    init(
        approve: @escaping @Sendable (Project, String) async throws -> Void = { _, _ in },
        makeRun: @escaping @Sendable (Project, String, RunOptions) throws -> RunHandle = { _, _, _ in
            RunHandle(run: {}, stop: {})
        },
        newThread: @escaping @Sendable (Project, String) async throws -> Void = { _, _ in },
        openGoal: @escaping @Sendable (Project, String) async throws -> Void = { _, _ in },
        requestStop: @escaping @Sendable (Project, String) async -> Bool = { _, _ in false },
        openWorktree: @escaping @Sendable (Project, String) async throws -> Void = { _, _ in },
        loadReview: @escaping @Sendable (Project, String) async -> ReviewReport? = { _, _ in nil },
        acceptPlan: @escaping @Sendable (Project, String) async throws -> AcceptPlan = { _, _ in throw Unset() },
        accept: @escaping @Sendable (Project, String, AcceptPlan, String?) async throws -> AcceptResult = { _, _, _, _ in
            throw Unset()
        },
        discardPlan: @escaping @Sendable (Project, String) async throws -> DiscardPlan = { _, _ in throw Unset() },
        discard: @escaping @Sendable (Project, String, DiscardPlan) async throws -> Void = { _, _, _ in },
        patch: @escaping @Sendable (Project, String, String) async throws -> FilePatch? = { _, _, _ in nil }
    ) {
        (self.approve, self.makeRun, self.newThread, self.openGoal) = (approve, makeRun, newThread, openGoal)
        (self.requestStop, self.openWorktree) = (requestStop, openWorktree)
        (self.loadReview, self.acceptPlan, self.accept) = (loadReview, acceptPlan, accept)
        (self.discardPlan, self.discard, self.patch) = (discardPlan, discard, patch)
    }

    struct Unset: Error, CustomStringConvertible { var description: String { "not available here" } }

    static let core = GoalActions(
        approve: { project, thread in
            let git = try GitRunner.discover()
            try await ThreadService(project: project, git: git).approve(id: thread)
        },
        makeRun: { project, thread, options in
            let runner = ThreadRunner(project: project, threadID: thread, git: try GitRunner.discover())
            return RunHandle(run: { _ = try await runner.run(options) }, stop: { await runner.stop() })
        },
        newThread: { project, name in
            let git = try GitRunner.discover()
            _ = try await ThreadService(project: project, git: git).newThread(name: name)
        },
        openGoal: { project, thread in try await openInEditor(project, thread) },
        requestStop: { project, thread in
            guard let git = try? GitRunner.discover() else { return false }
            if case .signalled = ThreadService(project: project, git: git).requestStop(id: thread) { return true }
            return false
        },
        openWorktree: { project, thread in
            let url = try Editor.worktree(project: project, threadID: thread)
            await MainActor.run { _ = NSWorkspace.shared.open(url) }
        },
        loadReview: { project, thread in
            guard let git = try? GitRunner.discover() else { return nil }
            return await ReviewLoader(project: project, git: git).load(id: thread)
        },
        acceptPlan: { project, thread in
            try await ThreadService(project: project, git: try GitRunner.discover()).acceptPlan(id: thread)
        },
        accept: { project, thread, plan, message in
            try await ThreadService(project: project, git: try GitRunner.discover())
                .accept(id: thread, message: message, shown: plan)
        },
        discardPlan: { project, thread in
            try await ThreadService(project: project, git: try GitRunner.discover()).discardPlan(id: thread)
        },
        discard: { project, thread, plan in
            try await ThreadService(project: project, git: try GitRunner.discover()).discard(id: thread, shown: plan)
        },
        patch: { project, thread, path in
            try await ReviewLoader(project: project, git: try GitRunner.discover()).patch(id: thread, path: path)
        })

    /// The goal file in the project's (else the global) `editor`, as `workbench open --goal` does; with none set, in the
    /// default app for the file rather than a refusal.
    static func openInEditor(_ project: Project, _ thread: String) async throws {
        let path = try Editor.goalFile(project: project, threadID: thread)
        let environment = ProcessInfo.processInfo.environment
        // Opening a file never depends on the config being right: a config that does not load (the goal screen says so) or a
        // global one that does not just means no configured editor, and the file opens in the default app.
        var editor = (try? Config.load(from: project.configURL))?.editor
        if editor == nil {
            editor = (try? GlobalConfig.load(from: GlobalConfig.defaultURL(environment: environment)))?.editor
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
