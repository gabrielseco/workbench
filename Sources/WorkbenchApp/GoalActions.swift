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
    /// One edit to a draft's goal file, as `ThreadService.editGoal` makes it.
    var editGoal: @Sendable (Project, String, GoalEdit) async throws -> Void
    var makeRun: @Sendable (Project, String, RunOptions) throws -> RunHandle
    /// Has the goal agent draft a goal from a rough request (and screenshots), as a new thread named `name`; `DraftStop` ends the drafter early.
    var draftGoal: DraftGoal
    /// Names the goal agent in the project's config, so a project with none can draft.
    var enableGoalAgent: @Sendable (Project, AgentProviderID) async throws -> Void
    var openGoal: @Sendable (Project, String) async throws -> Void
    /// Asks the process that holds the thread (a terminal's `workbench run`) to stop; false when nothing holds it.
    var requestStop: @Sendable (Project, String) async -> Bool
    var openWorktree: @Sendable (Project, String) async throws -> Void
    /// Whether a `herdr` executable is found for this project (its config, else PATH and the usual places): the button is shown only then.
    var herdrFound: @Sendable (Project) -> Bool
    /// Starts Herdr when its server is down, then opens the thread's worktree there and brings it forward.
    var openInHerdr: @Sendable (Project, String) async throws -> HerdrOpened
    /// The changed files' diffs in the editor: all of them, or the one at the path. Says what it left out, nil when nothing.
    var openDiff: @Sendable (Project, String, String?) async throws -> String?
    var loadReview: @Sendable (Project, String) async -> ReviewReport?
    /// The thread's denied calls with what was decided about each; empty when the thread's coding turns take no grants (Codex).
    var grantCandidates: @Sendable (Project, String) async throws -> [GrantCandidate]
    /// Records one decision, as `workbench grant <target> --once|--thread|--never` does; core's refusal comes back as its own text.
    var grant: @Sendable (Project, String, String, GrantScope, Bool) async throws -> Void
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
    /// What a fix round for the pull request `pr` of this thread would start, read from the log and the config; creates nothing.
    var followUpPlan: @Sendable (Project, String, Int) async throws -> FollowUpPlan
    /// Starts core's follow-up thread for the thread's pull request from a round's findings, and returns its id.
    /// The last argument is the budget the confirm showed: a project whose budget changed since is refused, not started dearer.
    var startFollowUp: @Sendable (Project, String, String, Int, Decimal?) async throws -> String

    init(
        approve: @escaping @Sendable (Project, String) async throws -> Void = { _, _ in },
        editGoal: @escaping @Sendable (Project, String, GoalEdit) async throws -> Void = { _, _, _ in },
        makeRun: @escaping @Sendable (Project, String, RunOptions) throws -> RunHandle = { _, _, _ in
            RunHandle(run: {}, stop: {})
        },
        draftGoal: @escaping DraftGoal = { _, _, _, _, _ in throw Unset() },
        enableGoalAgent: @escaping @Sendable (Project, AgentProviderID) async throws -> Void = { _, _ in },
        openGoal: @escaping @Sendable (Project, String) async throws -> Void = { _, _ in },
        requestStop: @escaping @Sendable (Project, String) async -> Bool = { _, _ in false },
        openWorktree: @escaping @Sendable (Project, String) async throws -> Void = { _, _ in },
        herdrFound: @escaping @Sendable (Project) -> Bool = { _ in false },
        openInHerdr: @escaping @Sendable (Project, String) async throws -> HerdrOpened = { _, _ in throw Unset() },
        openDiff: @escaping @Sendable (Project, String, String?) async throws -> String? = { _, _, _ in nil },
        loadReview: @escaping @Sendable (Project, String) async -> ReviewReport? = { _, _ in nil },
        grantCandidates: @escaping @Sendable (Project, String) async throws -> [GrantCandidate] = { _, _ in [] },
        grant: @escaping @Sendable (Project, String, String, GrantScope, Bool) async throws -> Void = { _, _, _, _, _ in },
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
        latestPRReview: @escaping @Sendable (Project, String) async -> PRReviewShown? = { _, _ in nil },
        followUpPlan: @escaping @Sendable (Project, String, Int) async throws -> FollowUpPlan = { _, _, _ in throw Unset() },
        startFollowUp: @escaping @Sendable (Project, String, String, Int, Decimal?) async throws -> String = { _, _, _, _, _ in
            throw Unset()
        }
    ) {
        (self.approve, self.makeRun, self.draftGoal, self.openGoal) = (approve, makeRun, draftGoal, openGoal)
        self.editGoal = editGoal
        self.enableGoalAgent = enableGoalAgent
        (self.requestStop, self.openWorktree, self.openDiff) = (requestStop, openWorktree, openDiff)
        (self.herdrFound, self.openInHerdr) = (herdrFound, openInHerdr)
        (self.loadReview, self.acceptPlan, self.accept) = (loadReview, acceptPlan, accept)
        (self.grantCandidates, self.grant) = (grantCandidates, grant)
        (self.discardPlan, self.discard, self.patch) = (discardPlan, discard, patch)
        (self.shipPreview, self.ship) = (shipPreview, ship)
        (self.prReview, self.latestPRReview) = (prReview, latestPRReview)
        (self.followUpPlan, self.startFollowUp) = (followUpPlan, startFollowUp)
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

    /// What a follow-up's turn is capped at: the config's default budget when it sets one, else nothing but its timeout.
    static func followUpBudget(_ config: Config) -> Decimal? {
        config.defaultBudgetConfigured ? config.defaultBudgetUSD : nil
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
        editGoal: { project, thread, edit in
            do {
                try await ThreadService(project: project, git: try GitRunner.discover()).editGoal(id: thread, edit)
            } catch let refusal as ThreadServiceError { throw RefusalText("\(refusal)") }
        },
        makeRun: { project, thread, options in
            let runner = ThreadRunner(project: project, threadID: thread, git: try GitRunner.discover())
            let adviceStop = AdviceStop()
            return RunHandle(
                run: {
                    let report = try await runner.run(options)
                    // `[review] auto`, as `workbench run` does it once the runner is gone: advice, never the turn's result.
                    let checkFailed = report.check.map { $0.result != .passed } ?? false
                    if report.result == .succeeded, !checkFailed,
                        let config = try? Config.load(from: project.configURL), !config.review.auto.isEmpty {
                        _ = await ThreadService(project: project, git: try GitRunner.discover())
                            .runAutoAdvice(id: thread, config: config, stop: adviceStop)
                    }
                },
                stop: {
                    await runner.stop()
                    adviceStop.stop()
                })
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
        // A config that does not load still shows the button: the click says why, where a hidden one would not.
        herdrFound: { project in (try? herdrExecutable(project)).map { $0 != nil } ?? true },
        openInHerdr: { project, thread in try await openInHerdr(project, thread) },
        openDiff: { project, thread, path in try await openDiffInEditor(project, thread, path: path) },
        loadReview: { project, thread in
            guard let git = try? GitRunner.discover() else { return nil }
            return await ReviewLoader(project: project, git: git).load(id: thread)
        },
        grantCandidates: { project, thread in
            // A grant is a Claude tool pattern: the Codex coding turn takes none, so nothing is offered for it.
            if let config = try? Config.load(from: project.configURL), config.resolvedRunAgent().provider != .claude { return [] }
            return try ThreadService(project: project, git: try GitRunner.discover()).grantCandidates(id: thread)
        },
        grant: { project, thread, target, scope, dangerous in
            do {
                _ = try await ThreadService(project: project, git: try GitRunner.discover())
                    .grant(id: thread, target: target, scope: scope, allowDangerous: dangerous)
            } catch let refusal as GrantError {
                throw RefusalText("\(refusal)")
            } catch let refusal as ThreadServiceError {
                throw RefusalText("\(refusal)")
            }
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
        },
        followUpPlan: { project, thread, pr in
            let config = try Config.load(from: project.configURL)
            let store = ThreadStore(project: project)
            let used = store.followUps(of: store.rootID(of: thread)).count
            let maxRounds = config.prReview.maxRounds
            return FollowUpPlan(
                pr: pr, round: used + 1, allowed: max(0, maxRounds - 1), budget: followUpBudget(config),
                refusal: used >= max(0, maxRounds - 1) ? "\(FollowUpError.tooMany(used: used, max: maxRounds))" : nil)
        },
        startFollowUp: { project, thread, findings, round, shown in
            let config = try Config.load(from: project.configURL)
            guard followUpBudget(config) == shown else {
                throw RefusalText("The project's budget changed since this was shown. Look at the fix round again.")
            }
            do {
                return try await ThreadService(project: project, git: try GitRunner.discover())
                    .startFollowUp(parent: thread, findings: findings, reviewRound: round, config: config)
            } catch let refusal as FollowUpError { throw RefusalText("\(refusal)") }
        })

    /// The `herdr` to run: the project's config key, else the global one, else the usual places. A config file that is there and
    /// does not load is an error, not "names none": the key it may hold could name a stand-in, and guessing would run the real one.
    static func herdrExecutable(_ project: Project) throws -> URL? {
        let environment = ProcessInfo.processInfo.environment
        var configured: String?
        do {
            if FileManager.default.fileExists(atPath: project.configURL.path) {
                configured = try Config.load(from: project.configURL).herdr
            }
            if configured == nil {
                configured = try GlobalConfig.load(from: GlobalConfig.defaultURL(environment: environment)).herdr
            }
        } catch {
            throw RefusalText("A config does not load, so it is not guessed which herdr to run: \(error)")
        }
        return HerdrLocator.find(configured: configured, searchPath: environment["PATH"], home: NSHomeDirectory())
    }

    /// Opens the thread's worktree in Herdr, starting the Herdr app first when its server is down.
    static func openInHerdr(_ project: Project, _ thread: String) async throws -> HerdrOpened {
        guard let executable = try herdrExecutable(project) else {
            throw RefusalText("Herdr was not found: install it, or name it in the config's `herdr` key.")
        }
        let folder = try Editor.worktree(project: project, threadID: thread)
        let client = HerdrClient(
            executable: executable, environment: HerdrClient.environment(from: ProcessInfo.processInfo.environment))
        let opener = HerdrOpener(client: client) {
            let found = await MainActor.run { NSWorkspace.shared.urlForApplication(withBundleIdentifier: "dev.herdr.app") }
            guard let app = found else {
                throw RefusalText("Herdr's server is not running and Herdr.app was not found to start it.")
            }
            _ = try await NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        }
        return try await opener.open(project: project.root, folder: folder, label: thread)
    }

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

    /// With no path, the thread's changes as uncommitted work in a folder of their own, opened in the configured editor (any
    /// editor: it lists every changed file); with one, that file's diff against the base in the editor's diff view. The note
    /// names what was left out.
    static func openDiffInEditor(_ project: Project, _ thread: String, path: String?) async throws -> String? {
        let environment = ProcessInfo.processInfo.environment
        guard let editor = configuredEditor(project: project, environment: environment) else { throw EditorError.notSet }
        if path == nil {
            let built = try await ReviewWorkspace.prepare(project: project, threadID: thread, git: try GitRunner.discover())
            let command = try Editor.command(
                for: editor, path: built.path.path, searchPath: environment["PATH"], isMacOS: Editor.isMacOS)
            try await EditorLauncher.launch(
                command, editor: editor, in: built.path, environment: Editor.environment(from: environment))
            var note = "\(built.changed) changed file(s) are open as uncommitted work; edits there do not go back to the thread"
            if !built.skipped.isEmpty { note += "; left out: " + built.skipped.prefix(5).joined(separator: ", ") }
            return note + "."
        }
        // The same containment check as opening the worktree: a folder swapped for a link must not make another checkout the root.
        let worktree = try Editor.worktree(project: project, threadID: thread)
        let git = try GitRunner.discover()
        guard let changes = await ReviewLoader(project: project, git: git).changedFiles(id: thread) else {
            throw EditorError.noWorktree(id: thread, path: project.worktreesDirectory.appendingPathComponent(thread).path)
        }
        let done = try await EditorDiff.open(
            files: changes.files, only: path, base: changes.base, worktree: worktree,
            scratch: project.threadDirectory(thread).appendingPathComponent("diff-base", isDirectory: true), git: git,
            editor: editor, environment: environment)
        var notes: [String] = []
        if !done.skipped.isEmpty { notes.append("\(done.skipped.count) binary or large file(s) not opened") }
        if done.more > 0 { notes.append("\(done.more) more changed file(s): click one to open it") }
        if done.opened.isEmpty, notes.isEmpty { notes.append("No changed files to open.") }
        return notes.isEmpty ? nil : notes.joined(separator: "; ") + "."
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
