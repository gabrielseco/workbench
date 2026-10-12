import Foundation

public enum ThreadServiceError: Error, Equatable, Sendable, CustomStringConvertible {
    case goalPlaceholdersRemain
    case goalMissing(String)
    case goalInvalid(String)
    case threadEnded(String)

    public var description: String {
        switch self {
        case .goalPlaceholdersRemain:
            "the goal still has TODO(workbench) placeholders. Write the request and criteria first."
        case .goalMissing(let path): "no goal at \(path)"
        case .goalInvalid(let problems): "the goal is not valid:\n\(problems)"
        case .threadEnded(let decision): "this thread has ended (\(decision))"
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
            try await log.append(.reviewDecision, data: ["decision": "abandoned", "by": "user"])
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
