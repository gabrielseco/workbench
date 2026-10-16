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

    public var description: String {
        switch self {
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
    func withLog<T>(_ id: String, _ body: (EventLogWriter) async throws -> T) async throws -> T {
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
    public func newThread(
        name: String, base: String? = nil, updating: String? = nil, config: Config? = nil
    ) async throws -> String {
        guard SafeNames.isThreadID(name) else { throw ThreadStoreError.invalidName(name) }
        if let updating {
            guard SafeNames.isPushTarget(updating) else { throw ThreadServiceError.invalidPushTarget(updating) }
            if base != nil { throw ThreadServiceError.updateWithBase }
            // Fails before anything is created when origin has no such branch.
            try await WorktreeManager(repoRoot: project.root, git: git).fetchRemoteBranch(updating)
        }
        let day = DateFormatter.dayStamp.string(from: now())
        let id = "g-\(day)-\(name)"
        try store.create(id: id)

        let baseBranch: String
        if let updating {
            baseBranch = "origin/\(updating)"
        } else if let base {
            baseBranch = base
        } else {
            baseBranch = await defaultBase()
        }
        let pushToLine = updating.map { "\npush_to: \($0)" } ?? ""
        let budget = NSDecimalNumber(decimal: config?.defaultBudgetUSD ?? Config.defaultBudgetUSD).stringValue
        let title = name.replacingOccurrences(of: "-", with: " ")

        let text = """
            ---
            id: \(id)
            title: \(title)
            status: draft
            base: \(baseBranch)\(pushToLine)
            budget_usd: \(budget)
            turn_timeout_min: 30
            # model: opus   (optional; unset = the config's model, else the claude CLI default)
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
            _ = try await log.recoverOrphanedVerify()
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
            _ = try await log.recoverOrphanedVerify()
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
        let state = store.state(of: id)
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
        let events = (try? EventLogReader.read(at: project.eventsURL(id)))?.events ?? []
        var commits: [String] = []
        if let base = events.last(where: { $0.kind == .worktreeCreated })?.data["base_commit"]?.stringValue {
            guard let found = await manager.commits(threadID: id, since: base) else {
                throw ThreadServiceError.acceptIncomplete("git could not list the commits on \(branch)")
            }
            commits = found
        }
        if pending.isEmpty && commits.isEmpty { throw ThreadServiceError.nothingToAccept }

        let report = await ReviewLoader(project: project, git: git).load(id: id)
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
            _ = try await log.recoverOrphanedVerify()
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

    /// The branch a thread is cut from when none is named: the checked-out one, else `main`.
    public func defaultBase() async -> String { await currentBranch() ?? "main" }

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
