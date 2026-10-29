import AppKit
import Foundation
import WorkbenchCore

/// A run this app started: `run` ends when the turn does, `stop` asks it to end (it still records a `stopped`).
struct RunHandle: Sendable {
    var run: @Sendable () async throws -> Void
    var stop: @Sendable () async -> Void
}

/// Ends the goal drafter the app started: a stop asked before the drafter is attached takes effect when it is.
final class DraftStop: @unchecked Sendable {
    private let lock = NSLock()
    private var stopper: (@Sendable () -> Void)?
    private var requested = false

    func attach(_ execution: AgentExecution) { attach { execution.stop() } }

    /// What ends the drafter; called at once when a stop was already asked.
    func attach(_ new: @escaping @Sendable () -> Void) {
        let stopNow = lock.withLock { () -> Bool in
            stopper = new
            return requested
        }
        if stopNow { new() }
    }

    func stop() {
        let running = lock.withLock { () -> (@Sendable () -> Void)? in
            requested = true
            return stopper
        }
        running?()
    }

    var wasRequested: Bool { lock.withLock { requested } }
}

/// What the screens' buttons do, as core does it. Seams so a test can see the order and the refusals without a repository.
struct GoalActions: Sendable {
    typealias DraftGoal = @Sendable (Project, String, String, [URL], DraftStop) async throws -> GoalDraftResult

    var approve: @Sendable (Project, String) async throws -> Void
    var makeRun: @Sendable (Project, String, RunOptions) throws -> RunHandle
    /// Has the goal agent draft a goal from a rough request (and screenshots), as a new thread named `name`; `DraftStop` ends the drafter early.
    var draftGoal: DraftGoal
    /// Names the goal agent in the project's config, so a project with none can draft.
    var enableGoalAgent: @Sendable (Project, AgentProviderID) async throws -> Void
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
    /// What Ship would push and open, with the title and body it would use: nothing is pushed.
    var shipPreview: @Sendable (Project, String) async throws -> ShipPreview
    /// Publishes what the preview showed; core refuses it when the target changed since.
    var ship: @Sendable (Project, String, ShipPreview) async throws -> ShipOutcome
    /// One Codex review round of the thread's pull request, recorded in its log.
    var prReview: @Sendable (Project, String) async throws -> PRReviewShown
    /// The latest recorded round with what Codex wrote; nil when none has run.
    var latestPRReview: @Sendable (Project, String) async -> PRReviewShown?

    init(
        approve: @escaping @Sendable (Project, String) async throws -> Void = { _, _ in },
        makeRun: @escaping @Sendable (Project, String, RunOptions) throws -> RunHandle = { _, _, _ in
            RunHandle(run: {}, stop: {})
        },
        draftGoal: @escaping DraftGoal = { _, _, _, _, _ in throw Unset() },
        enableGoalAgent: @escaping @Sendable (Project, AgentProviderID) async throws -> Void = { _, _ in },
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
        patch: @escaping @Sendable (Project, String, String) async throws -> FilePatch? = { _, _, _ in nil },
        shipPreview: @escaping @Sendable (Project, String) async throws -> ShipPreview = { _, _ in throw Unset() },
        ship: @escaping @Sendable (Project, String, ShipPreview) async throws -> ShipOutcome = { _, _, _ in throw Unset() },
        prReview: @escaping @Sendable (Project, String) async throws -> PRReviewShown = { _, _ in throw Unset() },
        latestPRReview: @escaping @Sendable (Project, String) async -> PRReviewShown? = { _, _ in nil }
    ) {
        (self.approve, self.makeRun, self.draftGoal, self.openGoal) = (approve, makeRun, draftGoal, openGoal)
        self.enableGoalAgent = enableGoalAgent
        (self.requestStop, self.openWorktree) = (requestStop, openWorktree)
        (self.loadReview, self.acceptPlan, self.accept) = (loadReview, acceptPlan, accept)
        (self.discardPlan, self.discard, self.patch) = (discardPlan, discard, patch)
        (self.shipPreview, self.ship) = (shipPreview, ship)
        (self.prReview, self.latestPRReview) = (prReview, latestPRReview)
    }

    struct Unset: Error, CustomStringConvertible { var description: String { "not available here" } }
    /// Why a round has no verdict, from the log of the thread that ran it (a follow-up's round is not in the parent's log).
    static func recordedFailure(_ record: PRReviewRecord, in project: Project) -> String? {
        let events = (try? EventLogReader.read(at: project.eventsURL(record.thread)))?.events ?? []
        guard let logged = ThreadState.derive(from: events, id: record.thread).review.prReview, logged.round == record.round,
            logged.pr == record.pr
        else { return nil }
        return logged.failure
    }

    /// A refusal from core in its own words, so the window shows the sentence and not the enum case's name.
    struct RefusalText: Error, CustomStringConvertible {
        var description: String
        init(_ description: String) { self.description = description }
    }

    static let core = GoalActions(
        approve: { project, thread in
            let git = try GitRunner.discover()
            try await ThreadService(project: project, git: git).approve(id: thread)
        },
        makeRun: { project, thread, options in
            let runner = ThreadRunner(project: project, threadID: thread, git: try GitRunner.discover())
            return RunHandle(run: { _ = try await runner.run(options) }, stop: { await runner.stop() })
        },
        draftGoal: { project, name, request, attachments, stop in
            let git = try GitRunner.discover()
            // A config that is there but broken is its own error, not "no goal agent".
            let config: Config? =
                FileManager.default.fileExists(atPath: project.configURL.path) ? try Config.load(from: project.configURL) : nil
            return try await ThreadService(project: project, git: git).draftGoal(
                target: .newThread(name: name, base: nil), request: request, config: config, attachments: attachments,
                attach: { stop.attach($0) })
        },
        enableGoalAgent: { project, provider in try GoalAgentSetup.enable(provider: provider, in: project) },
        openGoal: { project, thread in try await openInEditor(project, thread) },
        requestStop: { project, thread in
            guard let git = try? GitRunner.discover() else { return false }
            if case .signalled = ThreadService(project: project, git: git).requestStop(id: thread) { return true }
            return false
        },
        openWorktree: { project, thread in
            try await openWorktreeInEditor(project, thread)
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
        },
        shipPreview: { project, thread in try await ShipPreview.fetch(project: project, thread: thread) },
        ship: { project, thread, preview in try await ShipPreview.publish(preview, project: project, thread: thread) },
        prReview: { project, thread in
            let config = try Config.load(from: project.configURL)
            let service = ThreadService(project: project, git: try GitRunner.discover())
            do {
                return PRReviewShown(
                    try await service.prReview(id: thread, config: config, codexPath: config.executable(for: .codex)))
            } catch let refusal as PRReviewRefusal { throw RefusalText("\(refusal)") }
        },
        latestPRReview: { project, thread in
            guard let git = try? GitRunner.discover() else { return nil }
            let service = ThreadService(project: project, git: git)
            guard let record = service.latestPRReview(id: thread) else { return nil }
            return PRReviewShown(
                record, findings: service.prReviewFindings(record), failure: recordedFailure(record, in: project),
                tip: await service.pullRequestBranchTip(id: thread))
        })

    /// The editor to open a goal file in: the project's `editor`, else the one in `~/.workbench/config.toml`. A config that does not
    /// load counts as none (the goal screen says so), so opening a file never depends on the config being right.
    static func configuredEditor(project: Project, environment: [String: String]) -> String? {
        if let editor = (try? Config.load(from: project.configURL))?.editor { return editor }
        return (try? GlobalConfig.load(from: GlobalConfig.defaultURL(environment: environment)))?.editor
    }

    /// The worktree in the configured editor, as `workbench open` does. With none set it opens the folder in Finder, as it did
    /// before an editor could be chosen.
    static func openWorktreeInEditor(_ project: Project, _ thread: String) async throws {
        let url = try Editor.worktree(project: project, threadID: thread)
        let environment = ProcessInfo.processInfo.environment
        guard let editor = configuredEditor(project: project, environment: environment) else {
            await MainActor.run { _ = NSWorkspace.shared.open(url) }
            return
        }
        let command = try Editor.command(
            for: editor, path: url.path, searchPath: environment["PATH"], isMacOS: Editor.isMacOS)
        try await EditorLauncher.launch(command, editor: editor, in: url, environment: Editor.environment(from: environment))
    }

    /// The goal file in the configured editor, as `workbench open --goal` does. With none set it says so and how to set one: the
    /// file's default app is not a guess worth making (a Markdown file opens in Xcode on some machines).
    static func openInEditor(_ project: Project, _ thread: String) async throws {
        let path = try Editor.goalFile(project: project, threadID: thread)
        let environment = ProcessInfo.processInfo.environment
        guard let editor = configuredEditor(project: project, environment: environment) else { throw EditorError.notSet }
        let command = try Editor.command(
            for: editor, path: path.path, searchPath: environment["PATH"], isMacOS: Editor.isMacOS)
        try await EditorLauncher.launch(
            command, editor: editor, in: path.deletingLastPathComponent(), environment: Editor.environment(from: environment))
    }
}
