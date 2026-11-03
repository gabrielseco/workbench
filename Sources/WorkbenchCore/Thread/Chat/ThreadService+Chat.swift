import CryptoKit
import Foundation

/// Where a chat message goes: a new thread, or the conversation of an existing chat.
public enum ChatTarget: Sendable, Equatable {
    case newThread(name: String)
    case existing(id: String)
}

/// What one chat turn came to. A turn that fails is a result, not a thrown error: it has already spent what it spent, and its end
/// is in the log.
public struct ChatResult: Sendable, Equatable {
    public var id: String
    /// The agent's answer; nil when the turn produced none.
    public var reply: String?
    /// How the turn ended: `ok`, `stopped`, `timeout` or `failed`.
    public var end: String
    public var failure: String?
    public var costUSD: Double?
    public var provider: AgentProviderID
    public var model: String?
}

extension ThreadService {
    private struct PreparedChat: @unchecked Sendable {
        var agent: ResolvedAgent
        var provider: any AgentProvider
        var request: AgentRequest
        var work: URL
        var scratch: URL
    }

    /// Says `message` in a chat and records the agent's answer. Read-only: the agent works in an empty folder outside the checkout
    /// with nothing that writes, and the thread has no worktree, no branch and no goal. Bounded by a dollar cap or a timeout per
    /// turn and by the conversation's limits. Every turn ends: a `chat.ended` follows each user message, also when the turn is
    /// stopped, times out or crashes, and the next command closes one a killed process left.
    ///
    /// - Parameter attach: called with the running agent, so the caller can stop it (Ctrl-C).
    public func chat(
        target: ChatTarget, message: String, config: Config?, abandonActive: Bool = false,
        environment: [String: String] = ProcessInfo.processInfo.environment, timeout: TimeInterval = Chat.timeout,
        attach: @Sendable (AgentExecution) -> Void = { _ in }
    ) async throws -> ChatResult {
        guard let config, let agent = config.resolvedGoalAgent else { throw ChatRefusal.noGoalAgent }
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        var history: [ChatMessage] = []
        var spent = (0.0, false)
        var existing: String?
        switch target {
        case .newThread(let name):
            guard SafeNames.isThreadID(name) else { throw ChatRefusal.invalidName(name) }
        case .existing(let id):
            guard SafeNames.isThreadID(id) else { throw ChatRefusal.invalidName(id) }
            guard FileManager.default.fileExists(atPath: project.threadDirectory(id).path) else { throw ChatRefusal.noThread(id) }
            let state = ThreadStore(project: project).state(of: id)
            guard state.isChat else { throw ChatRefusal.notAChat(id) }
            if let decision = state.decision { throw ChatRefusal.ended(decision) }
            if let pid = runnerPID(id: id) { throw ChatRefusal.running(pid: pid) }
            history = state.chat?.messages ?? []
            spent = (state.chat?.costUSD ?? 0, state.chat?.costUnknown ?? false)
            existing = id
        }
        if let refusal = Chat.refusal(history: history, message: text, costUSD: spent.0, costUnknown: spent.1) { throw refusal }
        guard let provider = config.agentProvider(agent.provider) else {
            throw ChatRefusal.unavailable("there is no adapter for \(agent.provider)")
        }
        let decided = AgentSpendPolicy.spend(
            role: .goal, agent: agent, capabilities: provider.capabilities, cap: Chat.turnBudgetUSD, legacy: false,
            table: config.allowUnpricedTable(.goal))
        switch decided {
        case .failure(let refusal): throw ChatRefusal.spend(refusal.message)
        case .success(let spend):
            let executable = config.executable(for: agent.provider)
            guard ExecutableResolver.resolve(executable, searchPath: environment["PATH"]) != nil else {
                throw ChatRefusal.unavailable(Self.agentMissing(executable, provider: agent.provider))
            }
            return try await begin(
                target: target, existing: existing, text: text, history: history, config: config, agent: agent,
                provider: provider, spend: spend, abandonActive: abandonActive, environment: environment,
                timeout: timeout, attach: attach)
        }
    }

    // MARK: A turn

    private func begin(
        target: ChatTarget, existing: String?, text: String, history: [ChatMessage], config: Config, agent: ResolvedAgent,
        provider: any AgentProvider, spend: AgentSpend, abandonActive: Bool, environment: [String: String],
        timeout: TimeInterval, attach: @Sendable (AgentExecution) -> Void
    ) async throws -> ChatResult {
        var id = existing
        if case .newThread(let name) = target {
            id = try await createChatThread(name: name, abandonActive: abandonActive)
        }
        guard let id else { throw ChatRefusal.noThread("") }
        let prepared = try await prepare(
            id: id, text: text, history: history, config: config, agent: agent, provider: provider, spend: spend,
            environment: environment, timeout: timeout)
        defer {
            // Whatever the agent left running in its folder ends with the turn: a chat leaves no process behind.
            OrphanSweeper.sweep(inside: prepared.scratch)
            try? FileManager.default.removeItem(at: prepared.scratch)
        }
        do {
            return try await withLog(id) { log in
                try await self.turn(id: id, text: text, prepared: prepared, log: log, attach: attach)
            }
        } catch EventLogError.alreadyOpen { throw ChatRefusal.busy }
    }

    /// The thread of a new chat: a folder and a log that says it is a chat. No worktree, no branch and no goal file.
    private func createChatThread(name: String, abandonActive: Bool) async throws -> String {
        let store = ThreadStore(project: project)
        if let active = store.activeThreadID() {
            guard abandonActive else { throw ChatRefusal.activeThread(active) }
            _ = try await abandon(id: active)
        }
        do { try store.requireNoDoctor() } catch { throw ChatRefusal.doctorRunning }
        let day = DateFormatter.dayStamp.string(from: now())
        let id = try await createThreadDirectory(for: "g-\(day)-\(name)")
        do {
            try await withLog(id) { log in
                try await log.append(.threadCreated, data: ["kind": "chat", "repo": .string(self.project.root.path)])
            }
        } catch {
            try? FileManager.default.removeItem(at: project.threadDirectory(id))
            throw error
        }
        return id
    }

    private func prepare(
        id: String, text: String, history: [ChatMessage], config: Config, agent: ResolvedAgent, provider: any AgentProvider,
        spend: AgentSpend, environment: [String: String], timeout: TimeInterval
    ) async throws -> PreparedChat {
        let digest = SHA256.hash(data: Data(project.root.path.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("workbench-chat-\(digest)-\(id)")
        // An agent a killed process left behind is found by where it works, and ended, before another starts.
        OrphanSweeper.sweep(inside: scratch)
        try? FileManager.default.removeItem(at: scratch)
        let work = scratch.appendingPathComponent("work")
        let output = scratch.appendingPathComponent("out")
        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        } catch { throw ChatRefusal.unavailable("could not make a folder for the chat: \(error)") }
        let context = await draftContext(base: await defaultBase())
        let prompt = Chat.prompt(
            history: history, message: text, instructions: context.instructions, paths: context.paths, pathsCut: context.cut)
        let limits = AgentLimits(timeout: timeout, maxLineBytes: 1 << 20)
        var request: AgentRequest
        if agent.provider == .codex {
            let answer = output.appendingPathComponent("answer.txt")
            request = AgentRequest(
                provider: agent.provider, model: agent.model, prompt: prompt, workingDirectory: work, outputDirectory: output,
                policy: .readOnlyEvidence, spend: spend, purpose: .goal, environment: environment, limits: limits,
                answerFile: answer, reasoningEffort: agent.reasoningEffort)
            request.outsideRepository = true
        } else {
            request = AgentRequest(
                provider: agent.provider, model: agent.model, prompt: prompt, workingDirectory: work, outputDirectory: output,
                policy: .readOnlyEvidence, spend: spend, session: .start(proposed: UUID().uuidString.lowercased()),
                purpose: .goal, environment: environment, limits: limits, reasoningEffort: agent.reasoningEffort)
        }
        do {
            if let refusal = request.validate(against: provider) { throw refusal }
            _ = try provider.invocation(for: request)
        } catch {
            try? FileManager.default.removeItem(at: scratch)
            throw ChatRefusal.unavailable((error as? AgentFailure)?.message ?? "\(error)")
        }
        return PreparedChat(agent: agent, provider: provider, request: request, work: work, scratch: scratch)
    }

    /// One turn, with the log held: the message and the attempt are on record before anything is spent, and the end always follows.
    private func turn(
        id: String, text: String, prepared: PreparedChat, log: EventLogWriter, attach: @Sendable (AgentExecution) -> Void
    ) async throws -> ChatResult {
        // A turn a killed process left open ends here, before another is started.
        try await log.recoverOrphanedEvaluations()
        let agent = prepared.agent
        try? writeHolderMarker(id)
        defer { try? FileManager.default.removeItem(at: project.runnerURL(id)) }
        try await log.append(.chatMessage, data: ["role": "user", "text": .string(text)])
        let attempts = AttemptLog(log: log, role: "chat", turn: 0, agent: agent)
        let attempt = try await attempts.start()

        var result = ChatResult(id: id, reply: nil, end: "failed", provider: agent.provider, model: agent.model)
        let execution: AgentExecution?
        do { execution = try AgentRunner.start(provider: prepared.provider, request: prepared.request) } catch {
            execution = nil
            result.failure = Self.draftFailureText(error)
        }
        var outcome = "failed"
        if let execution {
            attach(execution)
            let completion = await execution.completion
            outcome = AttemptLog.outcome(of: completion.process, failure: completion.failure)
            result.costUSD = completion.usage?.costUSD
            let name = "\(agent.provider)"
            let limit = prepared.request.limits.timeout
            if let why = Self.draftProcessProblem(completion.process, timeout: limit, name: name) {
                result.failure = why
            } else if let failure = completion.failure {
                result.failure = failure.message
            } else {
                var written: String?
                if case .file(let url)? = completion.answer { written = Self.readAnswer(url) }
                let answer = (completion.summary ?? written)?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let answer, !answer.isEmpty {
                    result.reply = Self.chatReply(answer)
                    result.end = "ok"
                } else {
                    result.failure = "\(name) gave no answer"
                }
            }
            switch completion.process.cause {
            case .stopped: result.end = "stopped"
            case .timedOut: result.end = "timeout"
            case .natural: break
            }
        }
        try await attempts.end(attempt, outcome, reason: result.end == "ok" ? nil : result.failure)
        if let reply = result.reply { try await log.append(.chatMessage, data: ["role": "assistant", "text": .string(reply)]) }
        var ended: [String: JSONValue] = Self.agentFields(agent, ["ok": .bool(result.end == "ok"), "attempt": .string(attempt)])
        if result.end != "ok" {
            let why = result.end == "failed" ? (result.failure ?? "failed") : result.end
            ended["reason"] = .string(String(Self.withoutCredentials(PRBodyBuilder.scrub(why)).prefix(600)))
        }
        if let cost = result.costUSD { ended["cost_usd"] = .double(cost) }
        try await log.append(.chatEnded, data: .object(ended))
        if let failure = result.failure {
            result.failure = String(Self.withoutCredentials(PRBodyBuilder.scrub(failure)).prefix(600))
        }
        return result
    }

    /// A reply as it is kept: credentials scrubbed, and cut at the limit with a line saying so.
    static func chatReply(_ answer: String) -> String {
        let clean = withoutCredentials(PRBodyBuilder.scrub(answer))
        guard clean.utf8.count > Chat.replyLimit else { return clean }
        let kept = String(decoding: clean.utf8.prefix(Chat.replyLimit), as: UTF8.self)
        return kept + "\n[cut here at \(Chat.replyLimit / 1024) KiB]"
    }
}
