import Foundation

public enum VerifierRefusal: Error, Equatable, Sendable, CustomStringConvertible {
    case notConfigured
    case noTurn
    case alreadyVerified(turn: Int)
    case goalUnreadable(String)
    case skill(String)
    case noWorktree
    case claudeNotFound(String)
    case busy

    public var description: String {
        switch self {
        case .notConfigured:
            "this project turned the verifier off with [verifier] enabled = false in .workbench/config.toml."
        case .noTurn: "nothing to verify: no turn has run."
        case .alreadyVerified(let turn):
            "turn \(turn) was verified already (`workbench log` shows it). Pass --again to run it once more."
        case .goalUnreadable(let why): "the goal could not be read: \(why)"
        case .skill(let why): why
        case .noWorktree:
            "the thread has no worktree to drive (it was shipped, accepted or discarded); the verifier runs on the work in it."
        case .claudeNotFound(let name): "`\(name)` was not found"
        case .busy: "another command is using this thread (a run, a send-back or another verifier); try again when it ends."
        }
    }
}

extension ThreadService {
    /// Closes a verifier left open by a process that died, and ends what it left running in the worktree.
    func closeOrphanedVerifier(id: String, log: EventLogWriter) async throws {
        try await Verifier.recoverOrphan(
            log: log, worktree: WorktreeManager(repoRoot: project.root, git: git).path(for: id))
    }

    /// Runs the verifier on the latest turn and records `verifier.started` and `verifier.ended`. A separate `claude`
    /// run on the project's skill, read from the base commit, with the project's tools and its own session and
    /// budget; it opens no numbered turn, and nothing in Workbench treats what it says as a pass.
    ///
    /// The thread's log is held from the checks to the record, so a verifier, a judge and a run cannot spend on the
    /// same thread at once: the second is refused as `busy`.
    ///
    /// - Parameters:
    ///   - timeout: replaces `[verifier] timeout_min`. For tests.
    ///   - attach: called with the running process, so the caller can stop it (Ctrl-C).
    public func verifier(
        id: String, config: Config, again: Bool = false,
        environment: [String: String] = ProcessInfo.processInfo.environment, timeout: TimeInterval? = nil,
        killGrace: TimeInterval = 5, attach: @Sendable (ProcessRun) -> Void = { _ in }
    ) async throws -> VerifierReport {
        guard let verifier = config.verifier else { throw VerifierRefusal.notConfigured }
        if let pid = runnerPID(id: id) { throw ThreadServiceError.running(pid: pid) }
        do {
            return try await withLog(id) { log in
                try await self.verifierLocked(
                    id: id, log: log, config: config, verifier: verifier, again: again, environment: environment,
                    timeout: timeout ?? TimeInterval(verifier.timeoutMin) * 60, killGrace: killGrace, attach: attach)
            }
        } catch EventLogError.alreadyOpen { throw VerifierRefusal.busy }
    }

    private func verifierLocked(
        id: String, log: EventLogWriter, config: Config, verifier: VerifierConfig, again: Bool,
        environment: [String: String], timeout: TimeInterval, killGrace: TimeInterval,
        attach: @Sendable (ProcessRun) -> Void
    ) async throws -> VerifierReport {
        let events = (try? EventLogReader.read(at: project.eventsURL(id)))?.events ?? []
        let state = ThreadState.derive(from: events, id: id)
        guard state.lastTurn > 0 else { throw VerifierRefusal.noTurn }
        let turn = state.lastTurn
        if !again, events.contains(where: { $0.kind == .verifierEnded && $0.turn == turn && $0.data["ok"] == true }) {
            throw VerifierRefusal.alreadyVerified(turn: turn)
        }
        let goal: Goal
        do {
            goal = try GoalFile.parse(String(contentsOf: project.goalURL(id), encoding: .utf8)).goal
        } catch { throw VerifierRefusal.goalUnreadable("\(error)") }
        let manager = WorktreeManager(repoRoot: project.root, git: git)
        guard manager.exists(id) else { throw VerifierRefusal.noWorktree }
        guard let claude = ExecutableResolver.resolve(config.claudePath, searchPath: environment["PATH"]) else {
            throw VerifierRefusal.claudeNotFound(config.claudePath)
        }
        let recorded = events.last { $0.kind == .worktreeCreated }?.data["base_commit"]?.stringValue
        let base: String
        if let recorded { base = recorded } else {
            do { base = try await manager.commit(of: goal.base) } catch {
                throw VerifierRefusal.skill("the base commit could not be read, so the skill cannot be: \(error)")
            }
        }
        let skill: VerifierSkill
        switch await VerifierSkill.load(git: git, repo: project.root, commit: base, path: verifier.skill) {
        case .success(let loaded): skill = loaded
        case .failure(let problem): throw VerifierRefusal.skill(problem.description)
        }

        // This process is the thread's live holder while it runs (`stop` reaches it, a run or another verifier is
        // refused).
        try? writeHolderMarker(id)
        defer { try? FileManager.default.removeItem(at: project.runnerURL(id)) }
        try ThreadStore(project: project).requireNoDoctor()
        let run = VerifierRun(
            config: config, verifier: verifier, run: config.run, skill: skill, goal: goal, threadID: id,
            goalPath: project.goalURL(id).path, worktree: manager.path(for: id),
            proofDirectory: project.proofDirectory(id, turn: turn), threadDirectory: project.threadDirectory(id),
            claude: claude, environment: environment, timeout: timeout, killGrace: killGrace,
            identity: await ProofIdentity.of(worktree: manager.path(for: id), git: git, attributesFrom: base))
        return try await run.run(turn: turn, log: log, attach: attach)
    }
}

extension ThreadService {
    /// Whether a turn of this thread will be followed by a verifier: it is on and its skill is in the base commit.
    /// `log -f` waits for the verifier only then.
    public func verifierWillRun(id: String, config: Config) async -> Bool {
        guard let verifier = config.verifier,
            let contents = try? EventLogReader.read(at: project.eventsURL(id)),
            let base = contents.events.last(where: { $0.kind == .worktreeCreated })?.data["base_commit"]?.stringValue
        else { return false }
        if case .success = await VerifierSkill.load(git: git, repo: project.root, commit: base, path: verifier.skill) {
            return true
        }
        return false
    }
}

extension ThreadRunner {
    // MARK: The verifier step

    /// The project's verifier, run here after the check unless `[verifier] enabled = false`. Only after a turn that
    /// succeeded, whose check passed (or that has no check), that left a change to look at, and that no verifier
    /// has ended for already. Anything it cannot start (no skill at the base, no worktree change) is a
    /// `verifier.skipped` with the reason and a note, not a failure of the turn: it is advisory and costs nothing
    /// unless it runs. After a failed turn or check it is silent: a follower of the log knows from those.
    func runVerifier(
        after report: TurnReport, check: CheckReport?, config: Config, goal: Goal, worktree: URL, log: EventLogWriter,
        claude: URL?, options: RunOptions
    ) async throws -> VerifierReport? {
        guard let verifier = config.verifier, report.result == .succeeded else { return nil }
        if let check, check.result != .passed { return nil }
        let turn = report.turn
        if goal.skips("verifier") { return try await skip("the goal skips the verifier", turn: turn, log: log) }
        guard let base = await recordedBaseCommit(goal: goal) else {
            return try await skip("the base commit is unknown, so its skill cannot be read", turn: turn, log: log)
        }
        let skill: VerifierSkill
        switch await VerifierSkill.load(git: git, repo: project.root, commit: base, path: verifier.skill) {
        case .success(let loaded): skill = loaded
        case .failure(.missing): return nil  // most projects have no verify skill; that is not worth a line per turn
        case .failure(let problem): return try await skip("\(problem)", turn: turn, log: log)
        }
        if stopRequested { return try await skip("the run was stopped", turn: turn, log: log) }
        if let events = try? EventLogReader.read(at: project.eventsURL(threadID)).events,
            events.contains(where: { $0.kind == .verifierEnded && $0.turn == turn }) {
            return try await skip("a verifier has ended for this turn already", turn: turn, log: log)
        }
        guard await hasChange(worktree: worktree, base: base) else {
            return try await skip("the turn left no change to look at", turn: turn, log: log)
        }
        guard let claude else {
            return try await skip("claude was not found (claude_path), and the verifier runs on it", turn: turn, log: log)
        }
        let run = VerifierRun(
            config: config, verifier: verifier, run: config.run, skill: skill, goal: goal, threadID: threadID,
            goalPath: project.goalURL(threadID).path, worktree: worktree,
            proofDirectory: project.proofDirectory(threadID, turn: turn), threadDirectory: project.threadDirectory(threadID),
            claude: claude, environment: options.parentEnvironment,
            timeout: options.verifierTimeoutOverride ?? TimeInterval(verifier.timeoutMin) * 60, killGrace: options.killGrace,
            identity: await ProofIdentity.of(worktree: worktree, git: git, attributesFrom: base))
        notify(.verifierStarted(turn: turn, skill: skill.path))
        defer { currentRun = nil }
        let ran = try await run.run(turn: turn, log: log) { [self] process in
            Task { await self.attach(process) }
        }
        notify(.verifierEnded(ran))
        return ran
    }

    /// Why an automatic verifier did not start, said once in the log and as a note, so a follower of the log knows
    /// nothing more is coming and a person can see it was left out.
    private func skip(_ reason: String, turn: Int, log: EventLogWriter) async throws -> VerifierReport? {
        try await log.append(.verifierSkipped, turn: turn, data: ["reason": .string(reason)])
        notify(.advisory("the verifier did not run: \(reason)"))
        return nil
    }

    /// Whether the worktree holds anything to look at: a commit past the base, or edits (untracked files too).
    private func hasChange(worktree: URL, base: String) async -> Bool {
        if let head = try? await git.run(["rev-parse", "HEAD"], in: worktree), head.succeeded,
            head.stdout.trimmingCharacters(in: .whitespacesAndNewlines) != base {
            return true
        }
        guard let status = try? await git.run(["status", "--porcelain"], in: worktree), status.succeeded else { return true }
        return !status.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
