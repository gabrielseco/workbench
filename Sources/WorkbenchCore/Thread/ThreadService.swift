import Foundation

public enum ThreadServiceError: Error, Equatable, Sendable, CustomStringConvertible {
    case goalPlaceholdersRemain
    case goalMissing(String)
    case goalInvalid(String)
    case threadEnded(String)
    case running(pid: Int32)
    case nothingToDiscard
    case discardIncomplete(String)
    case changedSinceShown
    case nothingToAccept
    case worktreeMissing(String)
    case emptyMessage
    case invalidMessage(String)
    case acceptIncomplete(String)
    case changedSinceAcceptShown
    case invalidPushTarget(String)
    case updateWithBase
    case copySourceMissing(String)
    case copySourceTooLarge(String)
    case copyValueInvalid(String)
    case noFreeID(String)
    case abandonNotSaved(String)
    case budgetNeedsCap(provider: String)

    public var description: String {
        switch self {
        case .copySourceMissing(let path): "no goal file to copy at \(path)"
        case .copySourceTooLarge(let path): "\(path) is too large to be a goal file"
        case .copyValueInvalid(let problem): "the goal file to copy has a bad value: \(problem); nothing was created"
        case .abandonNotSaved(let why):
            "not abandoned: \(why). Nothing was removed. Commit what you want to keep, or `workbench discard` "
                + "throws it away after listing it."
        case .budgetNeedsCap(let provider):
            "\(provider) cannot enforce a dollar limit, and this goal has a budget_usd, so it was not approved. "
                + "Change the goal to `spend_policy: timeout_only` (and remove budget_usd), then approve it again."
        case .noFreeID(let id): "could not find a free id for '\(id)'; try another name"
        case .invalidPushTarget(let name):
            "'\(name)' cannot be updated: use a safe branch name that is not main, master, trunk or develop."
        case .updateWithBase:
            "--update already sets the base to that branch; drop --base."
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
        case .changedSinceShown:
            "the thread changed after the list was shown, so nothing was discarded. Run `workbench discard` again."
        case .nothingToAccept:
            "there is nothing to accept: the worktree has no changes and the branch has no commits beyond its base."
        case .worktreeMissing(let path): "no worktree at \(path), so there is no work to accept"
        case .emptyMessage: "the commit message is empty, so nothing was accepted"
        case .invalidMessage(let why): "the commit message is not usable: \(why)"
        case .acceptIncomplete(let what): what
        case .changedSinceAcceptShown:
            "the thread changed after the list and check were shown, so nothing was accepted. "
                + "Run `workbench accept` again."
        }
    }
}

/// What `newThread` runs once the thread and its first events exist, holding its log.
public typealias AfterCreate = @Sendable (_ id: String, _ log: EventLogWriter) async throws -> Void

/// Starting, approving and abandoning threads. Running them is `ThreadRunner`.
public struct ThreadService: Sendable {
    public let project: Project
    public let git: GitRunner
    public let now: @Sendable () -> Date
    /// Four lower-case hex digits that tell a repeated goal's id from the first run's; injectable for tests.
    public let idSuffix: @Sendable () -> String
    /// Tests only: called with the id of a new draft thread once it exists, to make the rest of its creation fail.
    var draftFault: (@Sendable (String) throws -> Void)?

    public init(
        project: Project, git: GitRunner, now: @escaping @Sendable () -> Date = { Date() },
        idSuffix: @escaping @Sendable () -> String = { String(format: "%04x", UInt16.random(in: .min ... .max)) }
    ) {
        self.project = project
        self.git = git
        self.now = now
        self.idSuffix = idSuffix
    }

    private var store: ThreadStore { ThreadStore(project: project) }

    /// Opens the thread's log for the duration of `body` and closes it before returning, so the next open
    /// never races a lingering close.
    @discardableResult
    func withLog<T>(_ id: String, _ body: (EventLogWriter) async throws -> T) async throws -> T {
        let log = try EventLogWriter.open(at: project.eventsURL(id), now: now)
        do {
            // Every command that opens the log first closes a plan its process left open (and ends what it left).
            try await closeOrphanedPlan(id: id, log: log)
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
    public func newThread(
        name: String, base: String? = nil, updating: String? = nil, config: Config? = nil,
        lineage: ThreadLineage? = nil, body: GoalBody? = nil, settings: GoalSettings = GoalSettings(),
        title proposedTitle: String? = nil, afterCreate: AfterCreate? = nil
    ) async throws -> String {
        guard SafeNames.isThreadID(name) else { throw ThreadStoreError.invalidName(name) }
        if let updating {
            guard SafeNames.isPushTarget(updating) else { throw ThreadServiceError.invalidPushTarget(updating) }
            if base != nil { throw ThreadServiceError.updateWithBase }
            // Fails before anything is created when origin has no such branch.
            try await WorktreeManager(repoRoot: project.root, git: git).fetchRemoteBranch(updating)
        }
        let day = DateFormatter.dayStamp.string(from: now())
        let id = try await createThreadDirectory(for: "g-\(day)-\(name)")

        let baseBranch: String
        if let updating {
            baseBranch = "origin/\(updating)"
        } else if let base {
            baseBranch = base
        } else {
            baseBranch = await defaultBase()
        }
        let pushToLine = updating.map { "\npush_to: \($0)" } ?? ""
        let spendLine =
            settings.timeoutOnly
            ? "spend_policy: timeout_only"
            : "budget_usd: "
                + NSDecimalNumber(decimal: settings.budgetUSD ?? config?.defaultBudgetUSD ?? Config.defaultBudgetUSD)
                .stringValue
        let title = proposedTitle ?? name.replacingOccurrences(of: "-", with: " ")
        let modelLine =
            settings.model.map { "model: \($0)" }
            ?? "# model: opus   (optional; unset = the config's model, else the claude CLI default)"

        let header = """
            ---
            id: \(id)
            \(FrontMatterLine(key: "title", value: title).rendered)
            status: draft
            base: \(baseBranch)\(pushToLine)
            \(spendLine)
            turn_timeout_min: \(settings.turnTimeoutMin ?? 30)
            \(modelLine)
            ---


            """
        let text = header + (body ?? GoalBody.placeholders).rendered
        try text.write(to: project.goalURL(id), atomically: true, encoding: .utf8)

        let manager = WorktreeManager(repoRoot: project.root, git: git)
        var created: [String: JSONValue] = [
            "repo": .string(project.root.path), "base": .string(baseBranch),
            "worktree": .string(manager.path(for: id).path),
            "branch": .string(WorktreeManager.branch(for: id)),
        ]
        if let lineage {
            created["parent"] = .string(lineage.parent)
            created["root"] = .string(lineage.root)
            created["round"] = .int(lineage.round)
        }
        try await withLog(id) { log in
            try await log.append(.threadCreated, data: .object(created))
            try await log.append(.goalSaved, data: ["status": "draft", "hash": .null])
            try await afterCreate?(id, log)
        }
        return id
    }

    // MARK: Approve

    /// Binds the current content of the goal with its hash. Nothing runs before this, and any later edit
    /// to the parts that matter returns it to draft.
    @discardableResult
    public func approve(id: String, config: Config? = nil) async throws -> GoalFile {
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
        let config = config ?? (try? Config.load(from: project.configURL))
        let agent = config?.resolvedRunAgent(goalModel: file.goal.model)
            ?? ResolvedAgent(provider: .claude, model: file.goal.model, allowUnpriced: false)
        // The run would refuse this goal, so say so now rather than after the approval.
        if agent.provider == .codex, file.goal.budgetUSD != nil { throw ThreadServiceError.budgetNeedsCap(provider: "codex") }
        let binding = ApprovedAgent(agent, spendPolicy: file.goal.spendPolicyName)
        // An unchanged goal is approved already; it is approved again only for coding settings it was not approved for.
        if file.goal.approval == .approved, store.state(of: id).approvedAgent == binding { return file }

        let approved = file.goal.approval == .approved ? file : try file.approving(at: now())
        if file.goal.approval != .approved { try approved.text.write(to: url, atomically: true, encoding: .utf8) }

        try await withLog(id) { log in
            try await log.append(
                .goalApproved,
                data: [
                    "hash": .string(approved.goal.contentHash),
                    // Absent for a timeout_only goal: there is no cap to record.
                    "budget_usd": approved.goal.budgetUSD.map { .double(NSDecimalNumber(decimal: $0).doubleValue) } ?? .null,
                    "spend_policy": .string(binding.spendPolicy),
                    "provider": .string(binding.provider),
                    "model": binding.model.map { .string($0) } ?? .null,
                    "reasoning_effort": binding.reasoningEffort.map { .string($0) } ?? .null,
                ])
        }
        return approved
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
        let report = await ReviewLoader(project: project, git: git).load(id: id, includeIgnored: true)
        let events = (try? EventLogReader.read(at: project.eventsURL(id)))?.events ?? []
        let created = events.contains { $0.kind == .worktreeCreated }
        // A discard that stopped halfway (worktree gone, branch left, or both gone) can be finished.
        guard manager.exists(id) || branchExists || created else { throw ThreadServiceError.nothingToDiscard }

        var commits: [String] = []
        var commitsKnown = true
        if branchExists {
            if let base = events.last(where: { $0.kind == .worktreeCreated })?.data["base_commit"]?.stringValue,
                let found = await manager.commits(threadID: id, since: base) {
                commits = found
            } else {
                commitsKnown = false
            }
        }
        return DiscardPlan(
            id: id, worktree: manager.exists(id) ? manager.path(for: id) : nil,
            branch: branchExists ? WorktreeManager.branch(for: id) : nil, diff: report.diff, commits: commits,
            commitsKnown: commitsKnown)
    }

    /// Throws the thread's work away: closes an open turn or check the runner left, removes the worktree
    /// and the branch, then records the decision. The decision comes last, so a failure partway leaves the
    /// thread active and running `discard` again finishes it.
    ///
    /// - Parameter shown: the plan the person confirmed. If the thread no longer matches it, nothing is
    ///   removed: new work that was never listed must not be deleted by an answer given about the old list.
    public func discard(id: String, shown: DiscardPlan? = nil, by: String = "user") async throws {
        let plan = try await discardPlan(id: id)
        if let shown, shown != plan { throw ThreadServiceError.changedSinceShown }
        let manager = WorktreeManager(repoRoot: project.root, git: git)
        try await withLog(id) { log in
            _ = try await log.recoverOrphanedTurn()
            _ = try await log.recoverOrphanedCheck()
            _ = try await log.recoverOrphanedEvaluations()
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

    // MARK: Accept

    /// What `accept` would commit and record, for the person to see first. Refuses an ended thread, a live
    /// runner, a missing worktree and a thread with nothing to accept.
    public func acceptPlan(id: String) async throws -> AcceptPlan {
        guard SafeNames.isThreadID(id) else { throw ThreadStoreError.invalidName(id) }
        // One replay serves the decision, the base commit and the review report below.
        let events = (try? EventLogReader.read(at: project.eventsURL(id)))?.events ?? []
        let state = ThreadState.derive(from: events, id: id)
        if let decision = state.decision { throw ThreadServiceError.threadEnded(decision) }
        if let pid = runnerPID(id: id) { throw ThreadServiceError.running(pid: pid) }

        let manager = WorktreeManager(repoRoot: project.root, git: git)
        guard manager.exists(id) else { throw ThreadServiceError.worktreeMissing(manager.path(for: id).path) }
        let worktree = manager.path(for: id)

        // The commit goes on workbench/<id> and nowhere else: a model that switched branches in its
        // worktree must not get its work committed to another one.
        let head = try await git.run(["symbolic-ref", "--short", "-q", "HEAD"], in: worktree)
        let branch = WorktreeManager.branch(for: id)
        guard head.succeeded, head.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == branch else {
            throw ThreadServiceError.acceptIncomplete(
                "the worktree is not on \(branch) (it is on "
                    + (head.succeeded ? head.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : "a detached HEAD")
                    + "), so nothing was accepted. Check it out there, or `workbench discard`.")
        }

        let pending: [String]
        do { pending = try await Self.pendingChanges(in: worktree, git: git) } catch {
            throw ThreadServiceError.acceptIncomplete("cannot read the worktree's changes: \(error)")
        }
        var commits: [String] = []
        if let base = events.last(where: { $0.kind == .worktreeCreated })?.data["base_commit"]?.stringValue {
            guard let found = await manager.commits(threadID: id, since: base) else {
                throw ThreadServiceError.acceptIncomplete("git could not list the commits on \(branch)")
            }
            commits = found
        }
        if pending.isEmpty && commits.isEmpty { throw ThreadServiceError.nothingToAccept }

        let report = await ReviewLoader(project: project, git: git).load(id: id, events: events)
        // Same-size edits keep paths and counts, so what was shown is also pinned by file identity.
        var snapshot = ""
        if case .summary(let shown) = report.diff {
            let full = try? await DiffProvider(git: git).summary(
                worktree: worktree, base: shown.base, limit: Int.max, includeIgnored: true, includeStaged: true)
            let stamps = (full?.workingFingerprint ?? [:]).sorted { $0.key < $1.key }
            snapshot = (full?.indexFingerprint ?? "") + "\n"
                + stamps.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
        }
        return AcceptPlan(
            id: id, worktree: worktree, branch: branch, diff: report.diff, hasPendingChanges: !pending.isEmpty,
            commits: commits, check: state.review.check,
            // Recovery will record these as interrupted, which is not a pass.
            openWork: state.openTurn != nil || state.openCheck != nil, snapshot: snapshot,
            defaultMessage: Self.defaultCommitMessage(id: id, goalURL: project.goalURL(id)))
    }

    /// Commits what is pending in the worktree (everything `review` lists; ignored files stay out), then
    /// records `accepted`. The decision comes last: a commit that fails (a hook, say) leaves the thread
    /// active with the changes staged, and running `accept` again finishes it. No push, no PR.
    ///
    /// - Parameter message: the commit message; the default from the goal when nil.
    /// - Parameter shown: the plan the person saw and confirmed. If the thread no longer matches it (new
    ///   work, a new check result), nothing is committed: the answer was about the old state.
    @discardableResult
    public func accept(
        id: String, message: String? = nil, shown: AcceptPlan? = nil, by: String = "user"
    ) async throws -> AcceptResult {
        let plan = try await acceptPlan(id: id)
        if let shown, shown != plan { throw ThreadServiceError.changedSinceAcceptShown }
        let text = (message ?? plan.defaultMessage).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { throw ThreadServiceError.emptyMessage }
        if text.utf8.count > 8_000 { throw ThreadServiceError.invalidMessage("longer than 8000 bytes") }
        if text.unicodeScalars.contains(where: { $0.value == 0 }) {
            throw ThreadServiceError.invalidMessage("it contains a NUL byte")
        }

        let worktree = plan.worktree
        return try await withLog(id) { log in
            var committedNow = false
            // The plan was made before the lock: a competing accept or discard may have ended the thread.
            if let decision = store.state(of: id).decision { throw ThreadServiceError.threadEnded(decision) }
            _ = try await log.recoverOrphanedTurn()
            _ = try await log.recoverOrphanedCheck()
            _ = try await log.recoverOrphanedEvaluations()
            // A child the dead runner left behind could still be writing files while they are committed.
            let swept = OrphanSweeper.sweep(inside: worktree)
            if !swept.isEmpty {
                _ = try await log.append(
                    EventKind(rawValue: "orphans.swept"), data: ["pids": .array(swept.map { .int(Int($0)) })])
            }

            // Always staged and asked of git, not taken from the plan: a user's `status.showUntrackedFiles`
            // must not make work that `review` lists look absent.
            do {
                let staged = try await git.run(["add", "-A"], in: worktree)
                guard staged.succeeded else {
                    throw ThreadServiceError.acceptIncomplete(
                        "git add failed, so nothing was committed and the thread is still active: "
                            + staged.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                // Exit 1 means something is staged. The message is one argv entry: no shell sees it.
                let differs = try await git.run(["diff", "--cached", "--quiet"], in: worktree)
                if differs.status == 1 {
                    committedNow = true
                } else if !differs.succeeded {
                    throw ThreadServiceError.acceptIncomplete(
                        "git could not compare the index, so nothing was committed and the thread is still "
                            + "active: " + differs.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
            if committedNow {
                let committed = try await git.run(["commit", "-q", "-m", text], in: worktree)
                guard committed.succeeded else {
                    let detail = (committed.stderr + committed.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
                    throw ThreadServiceError.acceptIncomplete(
                        "the commit failed, so nothing was accepted and the thread is still active; the "
                            + "changes are staged in the worktree. Fix the cause, then run `workbench accept` "
                            + "again.\n\(detail)")
                }
            }
            let left = (try? await Self.pendingChanges(in: worktree, git: git)) ?? ["?"]
            guard left.isEmpty else {
                throw ThreadServiceError.acceptIncomplete(
                    "the worktree is not clean after the commit (\(left.prefix(3).joined(separator: ", "))), so "
                        + "nothing was accepted. Look at it, then run `workbench accept` again.")
            }
            let head = try await git.run(["rev-parse", "--short=12", "HEAD"], in: worktree)
            let commit = head.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            try await log.append(
                .reviewDecision, data: ["decision": "accepted", "by": .string(by), "commit": .string(commit)])
            return AcceptResult(branch: plan.branch, commit: commit, committedNow: committedNow)
        }
    }

    /// Uncommitted work as porcelain lines, untracked files always included (ignored ones never).
    static func pendingChanges(in worktree: URL, git: GitRunner) async throws -> [String] {
        let result = try await git.run(["status", "--porcelain", "--untracked-files=all"], in: worktree)
        guard result.succeeded else {
            throw WorktreeError.gitFailed(command: "status", status: result.status, stderr: result.stderr)
        }
        return result.stdout.split(separator: "\n").map(String.init)
    }

    /// `chore: <goal title>`, then the request and the thread id. The type is a guess; edit it with `-m`.
    static func defaultCommitMessage(id: String, goalURL: URL) -> String {
        guard let text = try? String(contentsOf: goalURL, encoding: .utf8),
            let goal = try? GoalFile.parse(text).goal
        else { return "chore: \(id)\n\nWorkbench-Thread: \(id)" }
        let title = goal.title.trimmingCharacters(in: .whitespacesAndNewlines)
        var subject = "chore: " + (title.isEmpty ? id : title)
        if subject.count > 72 { subject = String(subject.prefix(71)) + "…" }
        let request = goal.request.trimmingCharacters(in: .whitespacesAndNewlines)
        return [subject, request, "Workbench-Thread: \(id)"].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    // MARK: Stop

    public enum StopResult: Equatable, Sendable {
        case signalled(pid: Int32)
        case notRunning
    }

    /// The pid of the `workbench run` holding this thread, if there is one (see `ThreadStore.runnerPID`).
    public func runnerPID(id: String) -> Int32? { store.runnerPID(id: id) }

    /// Asks the `workbench run` holding this thread to stop. It records the turn as `stopped` itself.
    public func requestStop(id: String) -> StopResult {
        guard let pid = runnerPID(id: id) else { return .notRunning }
        kill(pid, SIGTERM)
        return .signalled(pid: pid)
    }

    /// The branch a thread is cut from when none is named: the repo's default branch (what `origin/HEAD` points
    /// to, else a local `main`, else a local `master`), then the checked-out one, else `main`. Not simply the
    /// checked-out branch, which may be a feature branch.
    public func defaultBase() async -> String {
        if let remote = await originHead() { return remote }
        for name in ["main", "master"] where await localBranchExists(name) { return name }
        return await currentBranch() ?? "main"
    }

    private func originHead() async -> String? {
        guard
            let result = try? await git.run(
                ["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"], in: project.root),
            result.succeeded
        else { return nil }
        let ref = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ref.hasPrefix("origin/") else { return nil }
        let name = String(ref.dropFirst("origin/".count))
        return SafeNames.isBranchName(name) ? name : nil
    }

    private func localBranchExists(_ name: String) async -> Bool {
        let probe = try? await git.run(["show-ref", "--verify", "--quiet", "refs/heads/\(name)"], in: project.root)
        return probe?.succeeded ?? false
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
