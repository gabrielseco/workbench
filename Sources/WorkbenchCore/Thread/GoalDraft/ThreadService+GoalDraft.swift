import Foundation

/// Where a drafted goal goes: a new thread, or over the goal of an existing one (explicitly).
public enum GoalDraftTarget: Sendable, Equatable {
    case newThread(name: String, base: String?)
    case replace(id: String)
}

/// What `workbench goal draft` came to. A draft that fails is a result, not a thrown error: it has already spent
/// what it spent, and nothing was written for it.
public struct GoalDraftResult: Sendable, Equatable {
    /// The thread written or rewritten; nil when the draft did not produce a goal.
    public var id: String?
    public var replaced: Bool
    /// The goal that was replaced had been approved, and now needs `goal approve` again.
    public var wasApproved: Bool
    public var proposal: GoalProposal?
    public var provider: AgentProviderID
    /// Nil is the provider's own default.
    public var model: String?
    public var costUSD: Double?
    public var failure: String?

    public init(
        id: String?, replaced: Bool = false, wasApproved: Bool = false, proposal: GoalProposal? = nil,
        provider: AgentProviderID, model: String? = nil, costUSD: Double? = nil, failure: String? = nil
    ) {
        (self.id, self.replaced, self.wasApproved, self.proposal) = (id, replaced, wasApproved, proposal)
        (self.provider, self.model, self.costUSD, self.failure) = (provider, model, costUSD, failure)
    }
}

/// Why a draft was not started. Nothing was spawned, spent, written or logged.
public enum GoalDraftRefusal: Error, Equatable, Sendable, CustomStringConvertible {
    case noGoalAgent
    case emptyRequest
    case requestTooLong
    case spend(String)
    case unavailable(String)
    case invalidName(String)
    case invalidBase(String)
    case activeThread(String)
    case doctorRunning
    case noThread(String)
    case goalUnreadable(String)
    case ended(String)
    case running(pid: Int32)
    case busy
    case imagesNeedANewThread
    case attachment(String)

    public var description: String {
        switch self {
        case .noGoalAgent:
            "goal drafting is off: no [agents.goal] names a provider. Write the goal by hand: "
                + "`workbench goal new <name>`, then fill in the file it prints."
        case .emptyRequest: "the request is empty: say what the goal should be about (--request or --request-file)."
        case .requestTooLong: "the request is over \(GoalDraft.requestLimit / 1024) KiB; shorten it."
        case .spend(let why), .unavailable(let why): why
        case .invalidName(let name): "'\(name)' is not a usable thread name: letters, digits, '.', '_' and '-' only."
        case .invalidBase(let base): "'\(base)' is not a safe branch name."
        case .activeThread(let id): "thread \(id) is still active: finish or abandon it first (one thread at a time)."
        case .doctorRunning: "`workbench doctor` is running; try again when it ends."
        case .noThread(let id): "no thread \(id)."
        case .goalUnreadable(let why): "the goal could not be read: \(why)"
        case .ended(let decision): "this thread has ended (\(decision)); its goal cannot be replaced."
        case .running(let pid): "a run is live on this thread (pid \(pid)); stop it first."
        case .imagesNeedANewThread: "images can be attached to a new goal, not to a redrafted one."
        case .attachment(let why): why
        case .busy: "another command is using this thread (a run, a judge or another draft); try again when it ends."
        }
    }
}

extension ThreadService {
    /// What the drafter is asked, with the place it works and writes: an empty folder of its own, never the checkout.
    private struct PreparedDraft: @unchecked Sendable {
        var agent: ResolvedAgent
        var provider: any AgentProvider
        var request: AgentRequest
        var work: URL
        let base: String
        /// Removed when the draft ends.
        var scratch: URL?
        var existing: GoalFile?
        /// The user's screenshots, checked; shown to the drafter (when it can see them) and kept with a new thread.
        var attachments: [GoalAttachments.Loaded] = []
    }

    /// What one run of the drafter came to, for the caller to record.
    private struct DraftRun: Sendable {
        var proposal: GoalProposal?
        var failure: String?
        var cost: Double?
        var attemptOutcome = "failed"
        var attemptReason: String?
        var attempt: String?
    }

    /// Asks the goal agent for a draft of `request` and writes it as a draft goal: a new thread, or over an existing
    /// thread's goal (`replace`, which returns an approved goal to draft). Read-only and separate from any coding: no
    /// numbered turn, no worktree, and nothing in it approves or runs anything.
    ///
    /// The agent is asked once. Anything that is not a valid proposal (a failed process, a timeout, a stop, an answer
    /// that is not a goal) leaves the project exactly as it was.
    ///
    /// - Parameter attach: called with the running drafter, so the caller can stop it (Ctrl-C).
    public func draftGoal(
        target: GoalDraftTarget, request: String, config: Config?, attachments: [URL] = [],
        environment: [String: String] = ProcessInfo.processInfo.environment, timeout: TimeInterval = GoalDraft.timeout,
        attach: @Sendable (AgentExecution) -> Void = { _ in }
    ) async throws -> GoalDraftResult {
        let prepared = try await prepareDraft(
            target: target, request: request, config: config, attachments: attachments, environment: environment,
            timeout: timeout)
        defer { prepared.scratch.map { try? FileManager.default.removeItem(at: $0) } }
        switch target {
        case .replace(let id):
            do {
                return try await withLog(id) { log in
                    try await self.replaceLocked(id: id, prepared: prepared, log: log, attach: attach)
                }
            } catch EventLogError.alreadyOpen { throw GoalDraftRefusal.busy }
        case .newThread(let name, _):
            return try await newDraft(name: name, prepared: prepared, config: config, attach: attach)
        }
    }

    // MARK: Before anything is spent

    private func prepareDraft(
        target: GoalDraftTarget, request rough: String, config: Config?, attachments urls: [URL],
        environment: [String: String], timeout: TimeInterval
    ) async throws -> PreparedDraft {
        guard let config, let agent = config.resolvedGoalAgent else { throw GoalDraftRefusal.noGoalAgent }
        let text = rough.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw GoalDraftRefusal.emptyRequest }
        guard text.utf8.count <= GoalDraft.requestLimit, !text.contains("\0") else { throw GoalDraftRefusal.requestTooLong }
        guard let provider = config.agentProvider(agent.provider) else {
            throw GoalDraftRefusal.unavailable("there is no adapter for \(agent.provider)")
        }
        var images: [GoalAttachments.Loaded] = []
        if !urls.isEmpty {
            if case .replace = target { throw GoalDraftRefusal.imagesNeedANewThread }
            do { images = try GoalAttachments.load(urls) } catch { throw GoalDraftRefusal.attachment("\(error)") }
        }
        let spend: AgentSpend
        let decided = AgentSpendPolicy.spend(
            role: .goal, agent: agent, capabilities: provider.capabilities, cap: GoalDraft.budgetUSD, legacy: false,
            table: config.allowUnpricedTable(.goal))
        switch decided {
        case .success(let value): spend = value
        case .failure(let refusal): throw GoalDraftRefusal.spend(refusal.message)
        }

        let base: String
        var existing: GoalFile?
        switch target {
        case .newThread(let name, let named):
            guard SafeNames.isThreadID(name) else { throw GoalDraftRefusal.invalidName(name) }
            if let active = ThreadStore(project: project).activeThreadID() { throw GoalDraftRefusal.activeThread(active) }
            do { try ThreadStore(project: project).requireNoDoctor() } catch { throw GoalDraftRefusal.doctorRunning }
            if let named { base = named } else { base = await defaultBase() }
        case .replace(let id):
            guard SafeNames.isThreadID(id) else { throw GoalDraftRefusal.invalidName(id) }
            guard FileManager.default.fileExists(atPath: project.threadDirectory(id).path) else {
                throw GoalDraftRefusal.noThread(id)
            }
            if let decision = ThreadStore(project: project).state(of: id).decision { throw GoalDraftRefusal.ended(decision) }
            if let pid = runnerPID(id: id) { throw GoalDraftRefusal.running(pid: pid) }
            do {
                existing = try GoalFile.parse(String(contentsOf: project.goalURL(id), encoding: .utf8))
            } catch { throw GoalDraftRefusal.goalUnreadable("\(error)") }
            base = existing?.goal.base ?? ""
        }
        guard SafeNames.isBranchName(base) else { throw GoalDraftRefusal.invalidBase(base) }

        let executable = config.executable(for: agent.provider)
        guard ExecutableResolver.resolve(executable, searchPath: environment["PATH"]) != nil else {
            throw GoalDraftRefusal.unavailable(Self.agentMissing(executable, provider: agent.provider))
        }

        // The drafter works in an empty folder and writes its answer beside it, so it reads none of the checkout:
        // what it knows of the repository is the declared context in the prompt.
        // Both targets use a fresh folder outside the checkout (and outside the thread's folder, which sits in it),
        // removed when the draft ends; only a valid proposal is kept, beside the thread.
        let root = draftScratch(for: target)
        // A drafter a killed process left behind is found by where it works, and ended, before another starts. A
        // replacement has a folder of its own per thread for that; a new draft has no thread yet, so no stable place.
        if case .replace = target {
            OrphanSweeper.sweep(inside: root)
            try? FileManager.default.removeItem(at: root)
        }
        let scratch: URL? = root
        let work = root.appendingPathComponent("work")
        let output = root.appendingPathComponent("out")
        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        } catch { throw GoalDraftRefusal.unavailable("could not make a folder for the draft: \(error)") }

        let context = await draftContext(base: base)
        // A provider that takes images (Codex `-i`) is sent them from a folder beside the one it works in; one that opens files
        // (Claude's `Read`) finds them by name in the one folder it may read, which is otherwise empty.
        let sends = provider.capabilities.imageAttachments
        let names = GoalAttachments.names(images)
        let prompt = GoalDraft.prompt(
            request: text, instructions: context.instructions, paths: context.paths, pathsCut: context.cut,
            attachments: images.count, readFiles: sends ? [] : names)
        let shown: [URL]
        do {
            shown = try GoalAttachments.write(images, into: sends ? root.appendingPathComponent("images") : work)
        } catch {
            scratch.map { try? FileManager.default.removeItem(at: $0) }
            throw GoalDraftRefusal.unavailable("could not keep the images for the draft: \(error)")
        }
        let limits = AgentLimits(timeout: timeout, maxLineBytes: 1 << 20)
        let agentRequest: AgentRequest
        if agent.provider == .codex {
            let answer = output.appendingPathComponent("answer.txt")
            try? FileManager.default.removeItem(at: answer)
            var codex = AgentRequest(
                provider: agent.provider, model: agent.model, prompt: prompt, images: sends ? shown : [], workingDirectory: work,
                outputDirectory: output, policy: .readOnlyEvidence, spend: spend, purpose: .goal, environment: environment,
                limits: limits, answerFile: answer, reasoningEffort: agent.reasoningEffort)
            // The drafter's folder is an empty scratch folder outside any repository, which Codex otherwise refuses to start in.
            codex.outsideRepository = true
            agentRequest = codex
        } else {
            agentRequest = AgentRequest(
                provider: agent.provider, model: agent.model, prompt: prompt, workingDirectory: work,
                outputDirectory: output, policy: .readOnlyEvidence, spend: spend,
                session: .start(proposed: UUID().uuidString.lowercased()), purpose: .goal, environment: environment,
                limits: limits, evidenceFiles: sends ? [] : names, reasoningEffort: agent.reasoningEffort)
        }
        do {
            if let refusal = agentRequest.validate(against: provider) { throw refusal }
            _ = try provider.invocation(for: agentRequest)
        } catch {
            scratch.map { try? FileManager.default.removeItem(at: $0) }
            throw GoalDraftRefusal.unavailable((error as? AgentFailure)?.message ?? "\(error)")
        }
        return PreparedDraft(
            agent: agent, provider: provider, request: agentRequest, work: work, base: base, scratch: scratch,
            existing: existing, attachments: images)
    }

    /// The drafter's folder outside the checkout: stable for a replacement (so a leftover can be found), fresh for a new draft.
    func draftScratch(for target: GoalDraftTarget) -> URL {
        let temp = FileManager.default.temporaryDirectory
        guard case .replace(let id) = target else {
            return temp.appendingPathComponent("workbench-goal-draft-\(UUID().uuidString)")
        }
        let digest = SHA256.hash(data: Data(project.root.path.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        return temp.appendingPathComponent("workbench-goal-draft-\(digest)-\(id)")
    }

    /// The project's instructions and the tracked paths at the base: the repository context the prompt declares.
    private struct DraftContext {
        var instructions: String?
        var paths: [String]
        var cut: Bool
    }

    private func draftContext(base: String) async -> DraftContext {
        let instructions = await ProjectInstructions.load(git: git, repo: project.root, commit: base)?.text
        guard let listed = try? await git.run(["ls-tree", "-r", "--name-only", base], in: project.root), listed.succeeded else {
            return DraftContext(instructions: instructions, paths: [], cut: false)
        }
        let all = listed.stdout.split(separator: "\n").map(String.init).filter { $0.count <= 200 && !$0.contains("\0") }
        return DraftContext(
            instructions: instructions, paths: Array(all.prefix(GoalDraft.pathLimit)), cut: all.count > GoalDraft.pathLimit)
    }

    // MARK: One run of the drafter

    /// Starts the drafter and reads its answer. With a `log` (a replacement) the attempt and the draft are on record
    /// before anything is spent; without one (a new thread, which has no log yet) the caller records them afterwards.
    private func runDrafter(
        _ prepared: PreparedDraft, id: String?, log: EventLogWriter?, timeout: TimeInterval,
        attach: @Sendable (AgentExecution) -> Void
    ) async throws -> DraftRun {
        var attempts: AttemptLog?
        var run = DraftRun()
        if let log, let id {
            let writer = AttemptLog(log: log, role: "goal", turn: 0, agent: prepared.agent)
            attempts = writer
            OrphanSweeper.sweep(inside: prepared.work)
            do { try ThreadStore(project: project).requireNoDoctor() } catch { throw GoalDraftRefusal.doctorRunning }
            run.attempt = try await writer.start()
            try await log.append(
                .goalDraftStarted, data: .object(Self.agentFields(prepared.agent, ["attempt": .string(run.attempt ?? "")])))
            _ = id
        }
        let execution: AgentExecution
        do { execution = try AgentRunner.start(provider: prepared.provider, request: prepared.request) } catch {
            run.failure = Self.draftFailureText(error)
            run.attemptReason = run.failure
            if let attempts, let attempt = run.attempt { try await attempts.end(attempt, "failed", reason: run.failure) }
            return run
        }
        attach(execution)
        let completion = await execution.completion
        run.attemptOutcome = AttemptLog.outcome(of: completion.process, failure: completion.failure)
        if let attempts, let attempt = run.attempt { try await attempts.end(attempt, run.attemptOutcome) }
        run.cost = completion.usage?.costUSD

        let name = "\(prepared.agent.provider)"
        if let why = Self.draftProcessProblem(completion.process, timeout: timeout, name: name) {
            run.failure = why
        } else if let failure = completion.failure {
            run.failure = failure.message
        } else {
            var written: String?
            if case .file(let url)? = completion.answer { written = Self.readAnswer(url) }
            if let answer = completion.summary ?? written {
                do { run.proposal = try GoalDraft.proposal(fromAnswer: answer) } catch { run.failure = "\(error)" }
            } else {
                run.failure = "the proposal was not usable: no result"
            }
        }
        if let failure = run.failure {
            run.failure = String(Self.withoutCredentials(PRBodyBuilder.scrub(failure)).prefix(600))
        }
        return run
    }

    // MARK: A replacement

    private func replaceLocked(
        id: String, prepared: PreparedDraft, log: EventLogWriter, attach: @Sendable (AgentExecution) -> Void
    ) async throws -> GoalDraftResult {
        // A draft a killed process left open ends here, before another is started.
        try await log.recoverOrphanedEvaluations()
        let agent = prepared.agent
        let wasApproved = prepared.existing?.goal.approval == .approved
        // This process is the thread's live holder while it runs: `stop` reaches it, a run or a judge is refused.
        try? writeHolderMarker(id)
        defer { try? FileManager.default.removeItem(at: project.runnerURL(id)) }
        let run = try await runDrafter(
            prepared, id: id, log: log, timeout: prepared.request.limits.timeout, attach: attach)

        func finish(_ extra: [String: JSONValue]) async throws {
            var data = Self.agentFields(agent, extra)
            data["attempt"] = run.attempt.map { .string($0) } ?? .null
            if let cost = run.cost { data["cost_usd"] = .double(cost) }
            try await log.append(.goalDraftFinished, data: .object(data))
        }
        var result = GoalDraftResult(
            id: nil, replaced: true, wasApproved: wasApproved, proposal: nil, provider: agent.provider,
            model: agent.model, costUSD: run.cost, failure: nil)
        guard let proposal = run.proposal else {
            try await finish(["ok": false, "reason": .string(run.failure ?? "no proposal")])
            result.failure = run.failure
            return result
        }
        do {
            // The goal as it is now, so a front matter edit made while the agent ran is kept.
            let current = try GoalFile.parse(String(contentsOf: project.goalURL(id), encoding: .utf8))
            let updated = try current.redrafting(title: proposal.title, body: proposal.body)
            let reference = try keepProposal(proposal, id: id)
            try updated.text.write(to: project.goalURL(id), atomically: true, encoding: .utf8)
            try await log.append(.goalSaved, data: ["status": "draft", "hash": .null])
            try await finish(["ok": true, "proposal_ref": .string(reference)])
        } catch let error as EventLogError {
            throw error
        } catch {
            let why = "the goal could not be rewritten: \(error)"
            try await finish(["ok": false, "reason": .string(why)])
            result.failure = why
            return result
        }
        result.id = id
        result.proposal = proposal
        return result
    }

    /// The proposal as the agent made it, beside the thread, and its path relative to the thread's folder.
    private func keepProposal(_ proposal: GoalProposal, id: String) throws -> String {
        let folder = project.threadDirectory(id).appendingPathComponent("goal-draft")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try proposal.json.write(to: folder.appendingPathComponent("proposal.json"), atomically: true, encoding: .utf8)
        return "goal-draft/proposal.json"
    }

    // MARK: A new thread

    private func newDraft(
        name: String, prepared: PreparedDraft, config: Config?, attach: @Sendable (AgentExecution) -> Void
    ) async throws -> GoalDraftResult {
        let agent = prepared.agent
        let run = try await runDrafter(
            prepared, id: nil, log: nil, timeout: prepared.request.limits.timeout, attach: attach)
        var result = GoalDraftResult(
            id: nil, replaced: false, wasApproved: false, proposal: nil, provider: agent.provider, model: agent.model,
            costUSD: run.cost, failure: run.failure)
        guard let proposal = run.proposal else { return result }
        let made = MadeThread()
        do {
            // The thread exists only now. Its log tells the draft after the fact: the process left no thread behind
            // to write ahead into, and a draft that did not produce a goal leaves nothing at all.
            var body = proposal.body
            if !prepared.attachments.isEmpty {
                body.request += "\n\n" + GoalAttachments.markdown(GoalAttachments.names(prepared.attachments))
            }
            let id = try await newThread(
                name: name, base: prepared.base, config: config, body: body, title: proposal.title
            ) { id, log in
                made.id = id
                if !prepared.attachments.isEmpty {
                    let thread = self.project.threadDirectory(id)
                    let folder = thread.appendingPathComponent(GoalAttachments.folder, isDirectory: true)
                    _ = try GoalAttachments.write(prepared.attachments, into: folder)
                }
                try self.draftFault?(id)
                let reference = try self.keepProposal(proposal, id: id)
                let attempts = AttemptLog(log: log, role: "goal", turn: 0, agent: agent)
                let attempt = try await attempts.start()
                try await log.append(
                    .goalDraftStarted, data: .object(Self.agentFields(agent, ["attempt": .string(attempt)])))
                try await attempts.end(attempt, run.attemptOutcome, reason: run.attemptReason)
                var finished = Self.agentFields(
                    agent, ["ok": true, "proposal_ref": .string(reference), "attempt": .string(attempt)])
                if let cost = run.cost { finished["cost_usd"] = .double(cost) }
                try await log.append(.goalDraftFinished, data: .object(finished))
            }
            result.id = id
            result.proposal = proposal
        } catch {
            // A thread left half made would be an active, goal-less draft that blocks the next one: take it back.
            // Only the directory this draft made: another command may have made its own since the preflight.
            if let id = made.id { try? FileManager.default.removeItem(at: project.threadDirectory(id)) }
            result.failure = "the proposal was valid but no thread could be made for it: \(error)"
        }
        return result
    }

    private final class MadeThread: @unchecked Sendable {
        var id: String?
    }

    // MARK: Text

    private static func draftFailureText(_ error: Error) -> String {
        (error as? AgentFailure)?.message ?? "\(error)"
    }

    /// Why the drafter produced no answer to read, nil when it ended on its own with status 0.
    static func draftProcessProblem(_ exit: ProcessExit, timeout: TimeInterval, name: String) -> String? {
        if exit.cause == .stopped { return "the draft was stopped" }
        if exit.cause == .timedOut { return "\(name) did not answer within \(Int(timeout))s" }
        guard let problem = judgeProcessProblem(exit, timeout: timeout, name: name) else { return nil }
        // A bare "exited with status 1" leaves the person nothing to act on: the CLI's own last line says why.
        guard case .exited(let code) = exit.termination, code != 0 else { return problem }
        let lines = exit.stderrTail.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let last = lines.last(where: { !$0.isEmpty }) else { return problem }
        return "\(problem): \(last.prefix(240))"
    }
}
