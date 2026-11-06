import Foundation

/// Why an edit was not started or not accepted. Nothing was spawned, spent or written.
public enum TaskEditRefusal: Error, Equatable, Sendable, CustomStringConvertible {
    case noGoalAgent
    case emptyRequest
    case requestTooLong
    case spend(String)
    case unavailable(String)
    case noTask(String)
    case doesNotLoad(String)
    case running(String)
    case changedMeanwhile
    case notAProposal
    case invalidName(String)
    case taskExists(String)

    public var description: String {
        switch self {
        case .noGoalAgent:
            "editing a task needs an agent: no [agents.goal] names a provider. Edit .workbench/tasks/<name>/task.md by hand."
        case .emptyRequest: "the request is empty: say what should change in the task."
        case .requestTooLong: "the request is over \(TaskEdit.requestLimit / 1024) KiB; shorten it."
        case .spend(let why), .unavailable(let why): why
        case .noTask(let name): "no task \(name)."
        case .doesNotLoad(let why): "the task does not load as it is, so it cannot be edited: fix it first: \(why)"
        case .running(let name): "a run of \(name) is going: wait for it to end (an accepted edit would change its file)."
        case .changedMeanwhile: "the task file changed after this proposal was made: ask again."
        case .notAProposal: "there is no proposal to accept: it did not load."
        case .invalidName(let name): "'\(name)' is not a usable task name: letters, digits, '.', '_' and '-' only."
        case .taskExists(let name): "a task named \(name) exists already (.workbench/tasks/\(name)); nothing was changed."
        }
    }
}

/// An edit the agent proposed that loads: the whole new file, what it changes, and the file it was made from.
public struct TaskProposal: Sendable, Equatable {
    public var task: String
    public var text: String
    public var changes: TaskChanges
    /// The file on disk when the proposal was asked for, whole: `accept` writes only over this.
    public var source: String
    /// The task does not exist yet: accepting creates its folder and file instead of replacing a file.
    public var isNew: Bool

    public init(task: String, text: String, changes: TaskChanges, source: String, isNew: Bool = false) {
        (self.task, self.text, self.changes, self.source, self.isNew) = (task, text, changes, source, isNew)
    }
}

/// What one edit came to. An answer that does not load is a result, not a thrown error: it has spent what it spent and nothing was
/// written for it.
public struct TaskEditResult: Sendable, Equatable {
    public var proposal: TaskProposal?
    public var provider: AgentProviderID
    public var model: String?
    public var costUSD: Double?
    public var failure: String?

    public init(
        proposal: TaskProposal?, provider: AgentProviderID, model: String? = nil, costUSD: Double? = nil, failure: String? = nil
    ) {
        (self.proposal, self.provider, self.model, self.costUSD, self.failure) = (proposal, provider, model, costUSD, failure)
    }
}

/// Edits a task with the goal agent: asks once for a new `task.md`, checks it as the loader would, and says what it changes. Read-only
/// and no thread: the agent is given the file's text and returns text, so nothing is written, approved or run until `accept`, and
/// then only the file (an approval it had is then stale, and a person approves again).
public struct TaskEditor: Sendable {
    public let project: Project

    public init(project: Project) { self.project = project }

    /// - Parameter attach: called with the running agent, so the caller can stop it.
    public func propose(
        task name: String, request rough: String, config: Config?,
        environment: [String: String] = ProcessInfo.processInfo.environment, timeout: TimeInterval = TaskEdit.timeout,
        attach: @Sendable (AgentExecution) -> Void = { _ in }
    ) async throws -> TaskEditResult {
        guard let config, let agent = config.resolvedGoalAgent else { throw TaskEditRefusal.noGoalAgent }
        let request = rough.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty else { throw TaskEditRefusal.emptyRequest }
        guard request.utf8.count <= TaskEdit.requestLimit, !request.contains("\0") else { throw TaskEditRefusal.requestTooLong }
        let library = TaskLibrary(project: project)
        guard SafeNames.isThreadID(name), FileManager.default.fileExists(atPath: project.taskFileURL(name).path) else {
            throw TaskEditRefusal.noTask(name)
        }
        let source: String
        do {
            source = try library.source(name)
            _ = try library.loadText(source, name: name)
        } catch { throw TaskEditRefusal.doesNotLoad("\(error)") }
        if isRunning(name) { throw TaskEditRefusal.running(name) }

        let answer = try await ask(
            prompt: TaskEdit.prompt(task: name, current: source, request: request), config: config, agent: agent,
            environment: environment, timeout: timeout, attach: attach)
        var result = TaskEditResult(
            proposal: nil, provider: answer.provider, model: answer.model, costUSD: answer.costUSD, failure: answer.failure)
        if let text = answer.text {
            do { result.proposal = try proposal(name: name, source: source, answer: text) } catch {
                result.failure = clean("\(error)")
            }
        }
        return result
    }

    /// Asks the goal agent for a task that does not exist yet, from the template and the person's words. Nothing is written: the
    /// proposal loads as a task of that name, and `accept` makes its folder and file only if nobody has made them meanwhile.
    public func proposeNew(
        task name: String, request rough: String, config: Config?,
        environment: [String: String] = ProcessInfo.processInfo.environment, timeout: TimeInterval = TaskEdit.timeout,
        attach: @Sendable (AgentExecution) -> Void = { _ in }
    ) async throws -> TaskEditResult {
        guard let config, let agent = config.resolvedGoalAgent else { throw TaskEditRefusal.noGoalAgent }
        let request = rough.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty else { throw TaskEditRefusal.emptyRequest }
        guard request.utf8.count <= TaskEdit.requestLimit, !request.contains("\0") else { throw TaskEditRefusal.requestTooLong }
        guard SafeNames.isThreadID(name) else { throw TaskEditRefusal.invalidName(name) }
        guard !FileManager.default.fileExists(atPath: project.taskDirectory(name).path) else {
            throw TaskEditRefusal.taskExists(name)
        }
        do { try TaskScaffold.requireInsideProject(project) } catch { throw TaskEditRefusal.unavailable("\(error)") }
        let answer = try await ask(
            prompt: TaskEdit.newPrompt(task: name, template: TaskEdit.newTemplate(name: name), request: request), config: config,
            agent: agent, environment: environment, timeout: timeout, attach: attach)
        var result = TaskEditResult(
            proposal: nil, provider: answer.provider, model: answer.model, costUSD: answer.costUSD, failure: answer.failure)
        if let text = answer.text {
            do { result.proposal = try newProposal(name: name, answer: text) } catch { result.failure = clean("\(error)") }
        }
        return result
    }

    /// What one agent turn came to: its words, or why there are none.
    private struct Answer {
        var provider: AgentProviderID
        var model: String?
        var costUSD: Double?
        var failure: String?
        var text: String?
    }

    /// One read-only turn of the goal agent in an empty folder outside the checkout, given only the prompt. Refusals are thrown before
    /// anything is spawned; a turn that fails, is stopped or answers nothing is an `Answer` with its reason.
    private func ask(
        prompt: String, config: Config, agent: ResolvedAgent, environment: [String: String], timeout: TimeInterval,
        attach: @Sendable (AgentExecution) -> Void
    ) async throws -> Answer {
        guard let provider = config.agentProvider(agent.provider) else {
            throw TaskEditRefusal.unavailable("there is no adapter for \(agent.provider)")
        }
        let spend: AgentSpend
        switch AgentSpendPolicy.spend(
            role: .goal, agent: agent, capabilities: provider.capabilities, cap: TaskEdit.budgetUSD, legacy: false,
            table: config.allowUnpricedTable(.goal)
        ) {
        case .success(let value): spend = value
        case .failure(let refusal): throw TaskEditRefusal.spend(refusal.message)
        }
        let executable = config.executable(for: agent.provider)
        guard ExecutableResolver.resolve(executable, searchPath: environment["PATH"]) != nil else {
            throw TaskEditRefusal.unavailable(ThreadService.agentMissing(executable, provider: agent.provider))
        }

        // The agent works in an empty folder outside the checkout and is given the file's text, so it reads none of the project.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("workbench-task-edit-\(UUID().uuidString)")
        let (work, output) = (root.appendingPathComponent("work"), root.appendingPathComponent("out"))
        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        } catch { throw TaskEditRefusal.unavailable("could not make a folder for the edit: \(error)") }
        defer { try? FileManager.default.removeItem(at: root) }

        let limits = AgentLimits(timeout: timeout, maxLineBytes: 1 << 20)
        var agentRequest: AgentRequest
        if agent.provider == .codex {
            let answer = output.appendingPathComponent("answer.txt")
            agentRequest = AgentRequest(
                provider: agent.provider, model: agent.model, prompt: prompt, workingDirectory: work, outputDirectory: output,
                policy: .readOnlyEvidence, spend: spend, purpose: .goal, environment: environment, limits: limits,
                answerFile: answer, reasoningEffort: agent.reasoningEffort)
            agentRequest.outsideRepository = true
        } else {
            agentRequest = AgentRequest(
                provider: agent.provider, model: agent.model, prompt: prompt, workingDirectory: work, outputDirectory: output,
                policy: .readOnlyEvidence, spend: spend, session: .start(proposed: UUID().uuidString.lowercased()),
                purpose: .goal, environment: environment, limits: limits, reasoningEffort: agent.reasoningEffort)
        }
        do {
            if let refusal = agentRequest.validate(against: provider) { throw refusal }
            _ = try provider.invocation(for: agentRequest)
        } catch { throw TaskEditRefusal.unavailable(ThreadService.draftFailureText(error)) }

        var result = Answer(provider: agent.provider, model: agent.model, costUSD: nil, failure: nil, text: nil)
        let execution: AgentExecution
        do { execution = try AgentRunner.start(provider: provider, request: agentRequest) } catch {
            result.failure = clean(ThreadService.draftFailureText(error))
            return result
        }
        attach(execution)
        let completion = await execution.completion
        result.costUSD = completion.usage?.costUSD
        if let why = ThreadService.draftProcessProblem(completion.process, timeout: timeout, name: "\(agent.provider)") {
            result.failure = clean(why)
        } else if let failure = completion.failure {
            result.failure = clean(failure.message)
        } else {
            var written: String?
            if case .file(let url)? = completion.answer { written = ThreadService.readAnswer(url) }
            if let text = completion.summary ?? written {
                result.text = text
            } else {
                result.failure = "the proposal was not usable: no result"
            }
        }
        return result
    }


    /// The answer as a proposal, only when it loads as the task file would.
    func proposal(name: String, source: String, answer: String) throws -> TaskProposal {
        let text = try TaskEdit.file(fromAnswer: answer)
        let library = TaskLibrary(project: project)
        let old = try library.loadText(source, name: name)
        let new: LoadedTask
        do { new = try library.loadText(text, name: name) } catch {
            throw TaskEditError.unusable("it does not load as a task: \(error)")
        }
        return TaskProposal(
            task: name, text: text, changes: TaskChanges.compare(old: old.definition, new: new.definition), source: source)
    }

    /// The answer for a task that does not exist yet, only when it loads as a task of that name would, and does not still say TODO.
    func newProposal(name: String, answer: String) throws -> TaskProposal {
        let text = try TaskEdit.file(fromAnswer: answer)
        let loaded: LoadedTask
        do { loaded = try TaskLibrary(project: project).loadText(text, name: name) } catch {
            throw TaskEditError.unusable("it does not load as a task: \(error)")
        }
        guard !loaded.definition.instructions.contains(TaskScaffold.placeholder) else {
            throw TaskEditError.unusable("the instructions still say \(TaskScaffold.placeholder)")
        }
        return TaskProposal(
            task: name, text: text, changes: TaskChanges.creating(new: loaded.definition), source: "", isNew: true)
    }

    /// Makes the folder and file of a task that did not exist: the folder is claimed exclusively, so two accepts of one name, or a folder
    /// made meanwhile, cannot both succeed, and the one that lost never removes the winner's files. Nothing is approved.
    private func acceptNew(_ proposal: TaskProposal) throws {
        guard SafeNames.isThreadID(proposal.task) else { throw TaskEditRefusal.invalidName(proposal.task) }
        do { try TaskScaffold.requireInsideProject(project) } catch { throw TaskEditRefusal.unavailable("\(error)") }
        let directory = project.taskDirectory(proposal.task)
        guard !FileManager.default.fileExists(atPath: directory.path) else { throw TaskEditRefusal.taskExists(proposal.task) }
        do { try FileManager.default.createDirectory(at: project.tasksDirectory, withIntermediateDirectories: true) } catch {
            throw TaskEditRefusal.unavailable("the tasks folder could not be made: \(error)")
        }
        do { try TaskScaffold.claim(directory, name: proposal.task) } catch let error as TaskScaffoldError {
            if case .exists = error { throw TaskEditRefusal.taskExists(proposal.task) }
            throw TaskEditRefusal.unavailable("\(error)")
        }
        do { try proposal.text.write(to: project.taskFileURL(proposal.task), atomically: true, encoding: .utf8) } catch {
            // Only the folder this call claimed goes.
            try? FileManager.default.removeItem(at: directory)
            throw TaskEditRefusal.unavailable("the task file could not be written: \(error)")
        }
    }

    /// Writes the proposal as the task file, only if the file is still the one it was made from. Nothing is approved: the task reads
    /// stale if it was approved, and approving it again is a separate step.
    /// The run log's lock is held from the check that no run is going to the end of the write, and the file is read again under it, so a
    /// run that starts, or an edit made by hand, between the two cannot be written over. Both reads are `load`'s.
    public func accept(_ proposal: TaskProposal) throws {
        if proposal.isNew { return try acceptNew(proposal) }
        guard SafeNames.isThreadID(proposal.task) else { throw TaskEditRefusal.noTask(proposal.task) }
        guard let hold = holdRunLog(proposal.task) else { throw TaskEditRefusal.running(proposal.task) }
        defer { hold.release() }
        guard let now = try? TaskLibrary(project: project).source(proposal.task) else {
            throw TaskEditRefusal.noTask(proposal.task)
        }
        guard now == proposal.source else { throw TaskEditRefusal.changedMeanwhile }
        guard !proposal.changes.isEmpty else { return }
        do { try proposal.text.write(to: project.taskFileURL(proposal.task), atomically: true, encoding: .utf8) } catch {
            throw TaskEditRefusal.unavailable("the task file could not be written: \(error)")
        }
    }

    /// Whether a run of the task holds its log: a log nothing has written yet has no run.
    func isRunning(_ name: String) -> Bool {
        guard let hold = holdRunLog(name) else { return true }
        hold.release()
        return false
    }

    /// The lock a run holds on its log, taken without opening the log as a writer: opening one repairs a torn last line and writes a
    /// sidecar, and an edit must leave the task's folder as it was. Nil when a run holds it. The lock is `flock`'s, on the file's
    /// own descriptor, as `EventLogWriter` takes it.
    private struct LogHold {
        var descriptor: Int32
        func release() { if descriptor >= 0 { close(descriptor) } }
    }

    private func holdRunLog(_ name: String) -> LogHold? {
        let url = TaskRunLog(project: project, name: name).url
        guard FileManager.default.fileExists(atPath: url.path) else { return LogHold(descriptor: -1) }
        let fd = sysOpen(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return LogHold(descriptor: -1) }
        // A short wait, as the writer's own: a child process spawned elsewhere in this process shares the descriptor between fork and
        // exec, and that is not a run.
        let deadline = Date().addingTimeInterval(EventLogWriter.defaultLockTimeout)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR else { break }
            if Date() >= deadline {
                close(fd)
                return nil
            }
            usleep(2_000)
        }
        return LogHold(descriptor: fd)
    }

    private func clean(_ text: String) -> String {
        String(ThreadService.withoutCredentials(PRBodyBuilder.scrub(text)).prefix(600))
    }
}
