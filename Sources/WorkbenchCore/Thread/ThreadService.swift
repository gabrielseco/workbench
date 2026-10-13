import Foundation

public enum ThreadServiceError: Error, Equatable, Sendable, CustomStringConvertible {
    case goalPlaceholdersRemain
    case goalMissing(String)
    case goalInvalid(String)
    case threadEnded(String)
    case running(pid: Int32)
    case nothingToDiscard
    case discardIncomplete(String)

    public var description: String {
        switch self {
        case .goalPlaceholdersRemain:
            "the goal still has TODO(workbench) placeholders. Write the request and criteria first."
        case .goalMissing(let path): "no goal at \(path)"
        case .goalInvalid(let problems): "the goal is not valid:\n\(problems)"
        case .threadEnded(let decision): "this thread has ended (\(decision))"
        case .running(let pid):
            "a run is still working on this thread (pid \(pid)). `workbench stop` it first."
        case .nothingToDiscard:
            "this thread has no worktree and no branch to discard. `workbench abandon` ends it."
        case .discardIncomplete(let what): what
        }
    }
}

/// Starting, approving and abandoning threads. Running them is `ThreadRunner`.
public struct ThreadService: Sendable {
    public let project: Project
    public let git: GitRunner
    public let now: @Sendable () -> Date

    public init(project: Project, git: GitRunner, now: @escaping @Sendable () -> Date = { Date() }) {
        self.project = project
        self.git = git
        self.now = now
    }

    private var store: ThreadStore { ThreadStore(project: project) }

    /// Opens the thread's log for the duration of `body` and closes it before returning, so the next open
    /// never races a lingering close.
    @discardableResult
    private func withLog<T>(_ id: String, _ body: (EventLogWriter) async throws -> T) async throws -> T {
        let log = try EventLogWriter.open(at: project.eventsURL(id), now: now)
        do {
            let value = try await body(log)
            await log.close()
            return value
        } catch {
            await log.close()
            throw error
        }
    }

    // MARK: New

    /// Creates the thread directory, a draft goal to fill in and the first events. Refuses while another
    /// thread is active.
    public func newThread(name: String, base: String? = nil, config: Config? = nil) async throws -> String {
        guard SafeNames.isThreadID(name) else { throw ThreadStoreError.invalidName(name) }
        let day = DateFormatter.dayStamp.string(from: now())
        let id = "g-\(day)-\(name)"
        try store.create(id: id)

        let baseBranch: String
        if let base { baseBranch = base } else { baseBranch = await currentBranch() ?? "main" }
        let budget = NSDecimalNumber(decimal: config?.defaultBudgetUSD ?? Config.defaultBudgetUSD).stringValue
        let title = name.replacingOccurrences(of: "-", with: " ")

        let text = """
            ---
            id: \(id)
            title: \(title)
            status: draft
            base: \(baseBranch)
            budget_usd: \(budget)
            turn_timeout_min: 30
            ---

            ## Request

            TODO(workbench): say what should change, in a few sentences.

            ## Criteria

            - [c1] TODO(workbench): something that can be checked.
              - proof: TODO(workbench): how it will be shown (a test, a command, a screenshot).

            ## Out of scope

            - TODO(workbench): what must not change.
            """
        try text.write(to: project.goalURL(id), atomically: true, encoding: .utf8)

        let manager = WorktreeManager(repoRoot: project.root, git: git)
        try await withLog(id) { log in
            try await log.append(
                .threadCreated,
                data: [
                    "repo": .string(project.root.path), "base": .string(baseBranch),
                    "worktree": .string(manager.path(for: id).path),
                    "branch": .string(WorktreeManager.branch(for: id)),
                ])
            try await log.append(.goalSaved, data: ["status": "draft", "hash": .null])
        }
        return id
    }

    // MARK: Approve

    /// Binds the current content of the goal with its hash. Nothing runs before this, and any later edit
    /// to the parts that matter returns it to draft.
    @discardableResult
    public func approve(id: String) async throws -> GoalFile {
        if let decision = store.state(of: id).decision { throw ThreadServiceError.threadEnded(decision) }
        let url = project.goalURL(id)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw ThreadServiceError.goalMissing(url.path)
        }
        let file: GoalFile
        do { file = try GoalFile.parse(text) } catch let error as GoalParseError {
            throw ThreadServiceError.goalInvalid(error.description)
        }
        if text.contains("TODO(workbench)") { throw ThreadServiceError.goalPlaceholdersRemain }
        if file.goal.approval == .approved { return file }

        let approved = try file.approving(at: now())
        try approved.text.write(to: url, atomically: true, encoding: .utf8)

        try await withLog(id) { log in
            try await log.append(
                .goalApproved,
                data: [
                    "hash": .string(approved.goal.contentHash),
                    "budget_usd": .double(NSDecimalNumber(decimal: approved.goal.budgetUSD).doubleValue),
                ])
        }
        return approved
    }

    // MARK: Abandon

    /// Ends the thread without accepting its work: records the decision and removes the worktree. The branch
    /// is kept, so nothing the model committed is lost.
    public func abandon(id: String, force: Bool = false) async throws {
        if let decision = store.state(of: id).decision { throw ThreadServiceError.threadEnded(decision) }
        let manager = WorktreeManager(repoRoot: project.root, git: git)
        if manager.exists(id) { try await manager.remove(threadID: id, force: force) }

        try await withLog(id) { log in
            _ = try await log.recoverOrphanedTurn()
            _ = try await log.recoverOrphanedCheck()
            try await log.append(.reviewDecision, data: ["decision": "abandoned", "by": "user"])
        }
    }

    // MARK: Discard

    /// What `discard` would remove, for the confirmation. Refuses an ended thread and a live runner.
    public func discardPlan(id: String) async throws -> DiscardPlan {
        guard SafeNames.isThreadID(id) else { throw ThreadStoreError.invalidName(id) }
        let state = store.state(of: id)
        if let decision = state.decision { throw ThreadServiceError.threadEnded(decision) }
        if let pid = runnerPID(id: id) { throw ThreadServiceError.running(pid: pid) }

        let manager = WorktreeManager(repoRoot: project.root, git: git)
        let branchExists = try await manager.branchExists(id)
        let report = await ReviewLoader(project: project, git: git).load(id: id)
        let events = (try? EventLogReader.read(at: project.eventsURL(id)))?.events ?? []
        let created = events.contains { $0.kind == .worktreeCreated }
        // A discard that stopped halfway (worktree gone, branch left, or both gone) can be finished.
        guard manager.exists(id) || branchExists || created else { throw ThreadServiceError.nothingToDiscard }

        var commits: [String] = []
        if branchExists, let base = events.last(where: { $0.kind == .worktreeCreated })?
            .data["base_commit"]?.stringValue {
            commits = await manager.commits(threadID: id, since: base)
        }
        return DiscardPlan(
            id: id, worktree: manager.exists(id) ? manager.path(for: id) : nil,
            branch: branchExists ? WorktreeManager.branch(for: id) : nil, diff: report.diff, commits: commits)
    }

    /// Throws the thread's work away: closes an open turn or check the runner left, removes the worktree
    /// and the branch, then records the decision. The decision comes last, so a failure partway leaves the
    /// thread active and running `discard` again finishes it.
    public func discard(id: String, by: String = "user") async throws {
        _ = try await discardPlan(id: id)
        let manager = WorktreeManager(repoRoot: project.root, git: git)
        try await withLog(id) { log in
            _ = try await log.recoverOrphanedTurn()
            _ = try await log.recoverOrphanedCheck()
            if manager.exists(id) {
                // Children the dead runner left in the worktree would outlive it, and no later run sweeps it.
                let swept = OrphanSweeper.sweep(inside: manager.path(for: id))
                if !swept.isEmpty {
                    _ = try await log.append(
                        EventKind(rawValue: "orphans.swept"), data: ["pids": .array(swept.map { .int(Int($0)) })])
                }
                try await manager.remove(threadID: id, force: true)
            }
            do {
                if try await manager.branchExists(id) { try await manager.deleteBranch(threadID: id) }
            } catch {
                throw ThreadServiceError.discardIncomplete(
                    "the worktree is removed but branch \(WorktreeManager.branch(for: id)) could not be "
                        + "deleted: \(error)\nThe thread is still active. Fix that, then run `workbench discard` again.")
            }
            try await log.append(.reviewDecision, data: ["decision": "discarded", "by": .string(by)])
        }
    }

    // MARK: Stop

    public enum StopResult: Equatable, Sendable {
        case signalled(pid: Int32)
        case notRunning
    }

    /// The pid of the `workbench run` holding this thread, if there is one: same pid *and* same start time
    /// as recorded, so a process that merely reused the number is not mistaken for it.
    public func runnerPID(id: String) -> Int32? {
        guard
            let data = try? Data(contentsOf: project.runnerURL(id)),
            let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let pid = (info["pid"] as? NSNumber)?.int32Value,
            let seconds = (info["started_seconds"] as? NSNumber)?.uint64Value,
            let micros = (info["started_micros"] as? NSNumber)?.uint64Value
        else { return nil }
        let expected = ProcessMember(pid: pid, startSeconds: seconds, startMicros: micros)
        return ProcessTree.isAlive(expected) ? pid : nil
    }

    /// Asks the `workbench run` holding this thread to stop. It records the turn as `stopped` itself.
    public func requestStop(id: String) -> StopResult {
        guard let pid = runnerPID(id: id) else { return .notRunning }
        kill(pid, SIGTERM)
        return .signalled(pid: pid)
    }

    private func currentBranch() async -> String? {
        guard let result = try? await git.run(["rev-parse", "--abbrev-ref", "HEAD"], in: project.root),
            result.succeeded
        else { return nil }
        let name = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || name == "HEAD" ? nil : name
    }
}

extension DateFormatter {
    fileprivate static let dayStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}

/// What a discard would remove, shown before asking.
public struct DiscardPlan: Sendable, Equatable {
    public var id: String
    public var worktree: URL?
    public var branch: String?
    public var diff: ReviewReport.Diff
    /// `--oneline` of the commits on the branch that are not on its base.
    public var commits: [String]

    /// Everything that would be lost was listed: the diff could be read and was not cut.
    public var fullyShown: Bool {
        guard case .summary(let summary) = diff else { return worktree == nil }
        return !summary.truncated
    }

    public func render() -> [String] {
        var lines = ["discard \(id) will delete:"]
        if let worktree { lines.append("  worktree  \(worktree.path)") }
        if let branch { lines.append("  branch    \(branch)") }
        switch diff {
        case .summary(let summary):
            if summary.files.isEmpty { lines.append("  no changed files") }
            for file in summary.files { lines.append("  " + ReviewReport.describe(file)) }
            if summary.truncated {
                lines.append("  … and \(summary.totalFiles - summary.files.count) more files not listed")
            }
        case .unavailable(let reason):
            lines.append("  changes not shown: \(reason)")
        }
        if !commits.isEmpty {
            lines.append("  \(commits.count) commit\(commits.count == 1 ? "" : "s") on the branch, not on its base:")
            for commit in commits.prefix(10) { lines.append("    " + commit) }
            if commits.count > 10 { lines.append("    … and \(commits.count - 10) more") }
        }
        return lines
    }
}

/// The yes/no before a destructive command, kept out of the CLI so it can be tested.
public enum Confirmation: Equatable, Sendable {
    case proceed
    /// The person said no (or anything but yes). Nothing was changed.
    case declined
    /// No `--yes` and nobody to ask.
    case refused

    public static func ask(yes: Bool, interactive: Bool, readLine: () -> String?) -> Confirmation {
        if yes { return .proceed }
        guard interactive else { return .refused }
        guard let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() else { return .declined }
        return answer == "y" ? .proceed : .declined
    }
}
