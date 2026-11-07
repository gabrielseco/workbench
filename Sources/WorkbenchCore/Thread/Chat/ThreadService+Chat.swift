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

    public init(
        id: String, reply: String? = nil, end: String, failure: String? = nil, costUSD: Double? = nil,
        provider: AgentProviderID, model: String? = nil
    ) {
        (self.id, self.reply, self.end, self.failure) = (id, reply, end, failure)
        (self.costUSD, self.provider, self.model) = (costUSD, provider, model)
    }
}

extension ThreadService {
    private struct PreparedChat: @unchecked Sendable {
        var agent: ResolvedAgent
        var provider: any AgentProvider
        var request: AgentRequest
        var work: URL
        var scratch: URL
        /// The screenshots this message adds, under the names they are kept as; the earlier ones are already in the thread's folder.
        var fresh: [NamedImage] = []
    }

    /// What the person said in one message: its words and the screenshots sent with it.
    private struct Said: @unchecked Sendable {
        var text: String
        var images: [GoalAttachments.Loaded]
    }

    private struct NamedImage: @unchecked Sendable {
        var name: String
        var image: GoalAttachments.Loaded
    }

    /// Says `message` in a chat and records the agent's answer. Read-only: the agent works in an empty folder outside the checkout
    /// with nothing that writes, and the thread has no worktree, no branch and no goal. Bounded by a dollar cap or a timeout per
    /// turn and by the conversation's limits. Every turn ends: a `chat.ended` follows each user message, also when the turn is
    /// stopped, times out or crashes, and the next command closes one a killed process left.
    ///
    /// - Parameter attachments: screenshots sent with this message. They are checked before anything starts, kept with the thread, and
    ///   shown to the agent again on every later turn of the chat, up to `Chat.maxImages` in all.
    /// - Parameter attach: called with the running agent, so the caller can stop it (Ctrl-C).
    public func chat(
        target: ChatTarget, message: String, config: Config?, attachments: [URL] = [], abandonActive: Bool = false,
        environment: [String: String] = ProcessInfo.processInfo.environment, timeout: TimeInterval = Chat.timeout,
        attach: @Sendable (AgentExecution) -> Void = { _ in }
    ) async throws -> ChatResult {
        guard let config, let agent = config.resolvedGoalAgent else { throw ChatRefusal.noGoalAgent }
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let images: [GoalAttachments.Loaded]
        do { images = try GoalAttachments.load(attachments) } catch { throw ChatRefusal.attachment("\(error)") }
        var history: [ChatMessage] = []
        var spent = 0.0
        var existing: String?
        switch target {
        case .newThread(let name):
            guard SafeNames.isThreadID(name) else { throw ChatRefusal.invalidName(name) }
        case .existing(let id):
            guard SafeNames.isThreadID(id) else { throw ChatRefusal.invalidName(id) }
            guard FileManager.default.fileExists(atPath: project.threadDirectory(id).path) else { throw ChatRefusal.noThread(id) }
            let state = ThreadStore(project: project).state(of: id)
            guard state.isChat else { throw ChatRefusal.notAChat(id) }
            if FileManager.default.fileExists(atPath: project.goalURL(id).path) { throw ChatRefusal.hasGoal(id) }
            if let decision = state.decision { throw ChatRefusal.ended(decision) }
            if let pid = runnerPID(id: id) { throw ChatRefusal.running(pid: pid) }
            history = state.chat?.messages ?? []
            spent = state.chat?.costUSD ?? 0
            existing = id
        }
        if let refusal = Chat.refusal(history: history, message: text, costUSD: spent, newImages: images.count) { throw refusal }
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
                target: target, existing: existing, said: Said(text: text, images: images), history: history, config: config,
                agent: agent, provider: provider, spend: spend, abandonActive: abandonActive, environment: environment,
                timeout: timeout, attach: attach)
        }
    }

    // MARK: A turn

    private func begin(
        target: ChatTarget, existing: String?, said: Said, history: [ChatMessage], config: Config, agent: ResolvedAgent,
        provider: any AgentProvider, spend: AgentSpend, abandonActive: Bool, environment: [String: String],
        timeout: TimeInterval, attach: @Sendable (AgentExecution) -> Void
    ) async throws -> ChatResult {
        let (text, images) = (said.text, said.images)
        var id = existing
        if case .newThread(let name) = target {
            id = try await createChatThread(name: name, abandonActive: abandonActive)
        }
        guard let id else { throw ChatRefusal.noThread("") }
        let scratch = chatScratch(id)
        do {
            return try await withLog(id) { log in
                // Whatever the agent left running in its folder ends with the turn, while the log is still held: the next
                // submission cannot have taken the folder yet, and a refused one never reaches here to touch it.
                var holdsScratch = false
                defer {
                    if holdsScratch { Self.clearChatScratch(scratch) }
                }
                // What was checked before is checked again with the log held: another command may have decided, spent or started.
                let state = ThreadStore(project: self.project).state(of: id)
                guard state.isChat else { throw ChatRefusal.notAChat(id) }
                if FileManager.default.fileExists(atPath: self.project.goalURL(id).path) { throw ChatRefusal.hasGoal(id) }
                if let decision = state.decision { throw ChatRefusal.ended(decision) }
                let held = state.chat?.messages ?? []
                let total = state.chat?.costUSD ?? 0
                if let refusal = Chat.refusal(history: held, message: text, costUSD: total, newImages: images.count) {
                    throw refusal
                }
                do { try ThreadStore(project: self.project).requireNoDoctor() } catch { throw ChatRefusal.doctorRunning }
                holdsScratch = true
                let prepared = try await self.prepare(
                    id: id, said: said, history: held, config: config, agent: agent, provider: provider, spend: spend,
                    environment: environment, timeout: timeout)
                return try await self.turn(id: id, text: text, prepared: prepared, log: log, attach: attach)
            }
        } catch EventLogError.alreadyOpen { throw ChatRefusal.busy }
    }

    /// The agent's folder for a chat: one per thread and project, outside the checkout.
    func chatScratch(_ id: String) -> URL {
        let digest = SHA256.hash(data: Data(project.root.path.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        return FileManager.default.temporaryDirectory.appendingPathComponent("workbench-chat-\(digest)-\(id)")
    }

    /// Ends what is running in a chat's folder and removes it.
    static func clearChatScratch(_ scratch: URL) {
        OrphanSweeper.sweep(inside: scratch)
        try? FileManager.default.removeItem(at: scratch)
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
        id: String, said: Said, history: [ChatMessage], config: Config, agent: ResolvedAgent,
        provider: any AgentProvider, spend: AgentSpend, environment: [String: String], timeout: TimeInterval
    ) async throws -> PreparedChat {
        let (text, images) = (said.text, said.images)
        let scratch = chatScratch(id)
        // An agent a killed process left behind is found by where it works, and ended, before another starts.
        OrphanSweeper.sweep(inside: scratch)
        try? FileManager.default.removeItem(at: scratch)
        let work = scratch.appendingPathComponent("work")
        let output = scratch.appendingPathComponent("out")
        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        } catch { throw ChatRefusal.unavailable("could not make a folder for the chat: \(error)") }
        // Every screenshot of the chat, the earlier ones read back from the thread and this message's from memory, in the order sent.
        let earlier: [NamedImage]
        do { earlier = try storedChatImages(history, thread: id) } catch {
            try? FileManager.default.removeItem(at: scratch)
            throw error
        }
        let first = (earlier.compactMap { GoalAttachments.number(inStoredName: $0.name) }.max() ?? 0) + 1
        let fresh = images.enumerated().map { NamedImage(name: "\(first + $0.offset).\($0.element.ext)", image: $0.element) }
        let everything = earlier + fresh
        // A provider that takes images (Codex `-i`) is sent them from a folder beside the one it works in; one that opens files
        // (Claude's `Read`) finds them by name in the one folder it may read, which is otherwise empty.
        let sends = provider.capabilities.imageAttachments
        let names = everything.map(\.name)
        var shown: [URL] = []
        do {
            let folder = sends ? scratch.appendingPathComponent("images") : work
            if !everything.isEmpty { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
            for item in everything {
                let url = folder.appendingPathComponent(item.name)
                try item.image.data.write(to: url, options: .atomic)
                shown.append(url)
            }
        } catch {
            try? FileManager.default.removeItem(at: scratch)
            throw ChatRefusal.unavailable("could not keep the screenshots for the chat: \(error)")
        }
        let base = await defaultBase()
        let context = await draftContext(base: base)
        // The code at the base, copied for this turn and removed with the folder; no copy when it cannot be made or the config says no.
        let snapshot =
            config.chatReadsRepo
            ? await RepoSnapshotWriter.write(base: base, into: work, repo: project.root, git: git) : nil
        let prompt = Chat.prompt(
            history: history, message: text, instructions: context.instructions, paths: context.paths, pathsCut: context.cut,
            images: names, newImages: fresh.map(\.name), readFiles: !sends && !names.isEmpty, repo: snapshot,
            usesShell: agent.provider == .codex)
        let limits = AgentLimits(timeout: timeout, maxLineBytes: 1 << 20)
        var request: AgentRequest
        if agent.provider == .codex {
            let answer = output.appendingPathComponent("answer.txt")
            request = AgentRequest(
                provider: agent.provider, model: agent.model, prompt: prompt, images: sends ? shown : [], workingDirectory: work,
                outputDirectory: output, policy: .readOnlyEvidence, spend: spend, purpose: .goal, environment: environment,
                limits: limits, answerFile: answer, reasoningEffort: agent.reasoningEffort)
            request.outsideRepository = true
        } else {
            request = AgentRequest(
                provider: agent.provider, model: agent.model, prompt: prompt, workingDirectory: work, outputDirectory: output,
                policy: .readOnlyEvidence, spend: spend, session: .start(proposed: UUID().uuidString.lowercased()),
                purpose: .goal, environment: environment, limits: limits, evidenceFiles: sends ? [] : names,
                reasoningEffort: agent.reasoningEffort)
            request.readsFolder = snapshot != nil
        }
        do {
            if let refusal = request.validate(against: provider) { throw refusal }
            _ = try provider.invocation(for: request)
        } catch {
            try? FileManager.default.removeItem(at: scratch)
            throw ChatRefusal.unavailable((error as? AgentFailure)?.message ?? "\(error)")
        }
        return PreparedChat(agent: agent, provider: provider, request: request, work: work, scratch: scratch, fresh: fresh)
    }

    /// The screenshots the chat's earlier messages sent, read back from the thread's folder by the names its log holds (only names
    /// this feature writes get this far), checked again as images: a file that went missing or was swapped refuses the turn.
    private func storedChatImages(_ history: [ChatMessage], thread id: String) throws -> [NamedImage] {
        let folder = project.threadDirectory(id).appendingPathComponent(Chat.imagesFolder, isDirectory: true)
        return try history.flatMap(\.images).map { name in
            do { return NamedImage(name: name, image: try GoalAttachments.load(folder.appendingPathComponent(name))) } catch {
                let why = "screenshot \(name) of this chat can no longer be read (\(error)): start another chat."
                throw ChatRefusal.unavailable(why)
            }
        }
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
        // Doctor looks for a holder's marker: one that began while the folder was being made is seen here, now that it can see us.
        do { try ThreadStore(project: project).requireNoDoctor() } catch { throw ChatRefusal.doctorRunning }
        var said: [String: JSONValue] = ["role": "user", "text": .string(text)]
        if !prepared.fresh.isEmpty {
            // Kept before the message is on record, so a message never names a screenshot that is not there.
            let folder = project.threadDirectory(id).appendingPathComponent(Chat.imagesFolder, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for item in prepared.fresh {
                    try item.image.data.write(to: folder.appendingPathComponent(item.name), options: .atomic)
                }
            } catch { throw ChatRefusal.unavailable("could not keep the screenshots with the chat: \(error)") }
            said["images"] = .array(prepared.fresh.map { .string($0.name) })
        }
        try await log.append(.chatMessage, data: .object(said))
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
