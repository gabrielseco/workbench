import Foundation

/// What a Codex coding turn needs that a Claude turn does not: a refusal of what the provider cannot do, and the context
/// that stands in for a conversation it does not keep.
extension ThreadRunner {
    /// The diff given to a fresh process, and the files named beside it (untracked ones are not in a diff).
    static let continuationDiffLimit = 60_000
    static let continuationUntrackedLimit = 20

    /// Refuses, before anything is touched, what the coding provider cannot do. Claude can do all of it.
    static func requireProviderCanCode(agent: ResolvedAgent, goal: Goal, options: RunOptions) throws {
        guard agent.provider == .codex else { return }
        if goal.budgetUSD != nil {
            throw RunnerError.codingUnsupported(
                "codex cannot enforce a dollar limit, and this goal has a budget_usd. Change the goal to "
                    + "`spend_policy: timeout_only` (and remove budget_usd), then run `workbench goal approve` again.")
        }
        if options.budgetOverride != nil {
            throw RunnerError.invalidBudget(
                "codex has no dollar cap, so there is no budget to override; the turn is bounded by its timeout "
                    + "(turn_timeout_min in the goal)")
        }
    }

    static let summaryLimit = 4000

    /// The Codex prompt: the standing rules at its head (Codex has no system prompt), and for a thread's next turn the context
    /// a fresh process needs. `info` is what `turn.started` records about the prompt, plus the continuation.
    func codexPrompt(
        first: String, info: [String: JSONValue], followUp: (feedback: String?, check: CheckAttachment?)?, worktree: URL,
        base: String, config: Config
    ) async -> (String, [String: JSONValue]) {
        var prompt = first
        var info = info
        if let followUp {
            let context = await codexContinuationContext(worktree: worktree, base: base)
            prompt = PromptBuilder.codexContinuation(
                first: first, summary: context.summary, diff: context.diff, diffCut: context.diffCut,
                untracked: context.untracked, check: followUp.check, feedback: followUp.feedback)
            info["continuation"] = context.info
        }
        return (PromptBuilder.codexRules(checkCommand: config.checkCommand) + "\n\n" + prompt, info)
    }

    /// A rerun after a turn that did not finish (allowed without `--feedback` until a turn succeeds): a Codex process is fresh, so
    /// it is given where the work stands and the failed check, as a follow-up is. Claude resumes its session instead. Nil for
    /// the first turn and on Claude.
    func codexRerun(
        store: ThreadStore, lastTurn: Int, config: Config, goal: Goal
    ) -> (feedback: String?, check: CheckAttachment?)? {
        guard lastTurn > 0, config.resolvedRunAgent(goalModel: goal.model).provider == .codex else { return nil }
        guard let check = store.state(of: threadID).review.check, check.result != "passed" else { return (nil, nil) }
        let output = CheckAttachment.load(
            from: project.checkOutputURL(threadID, turn: check.turn), turn: check.turn, result: check.result,
            exitCode: check.exitCode)
        return (nil, output)
    }

    /// The `claude` the automatic verifier runs on: the coding executable when that is Claude, else `claude_path`, which may
    /// be missing (the verifier is then skipped, with the reason).
    func verifierClaude(config: Config, executable: URL, options: RunOptions) -> URL? {
        guard config.resolvedRunAgent().provider != .claude else { return executable }
        return ExecutableResolver.resolve(config.claudePath, searchPath: options.parentEnvironment["PATH"])
    }

    /// What a turn's end record says about the session and the refusals. A Codex turn has no session to resume and reports
    /// no refusals (unknown, not 0); it keeps what it said last, for the next turn's context.
    func providerFields(sessionID: String, denials: Int, summary: String?) -> [String: JSONValue] {
        guard codingProvider != .claude else { return ["session_id": .string(sessionID), "permission_denials": .int(denials)] }
        var fields: [String: JSONValue] = ["permission_denials": .null]
        if let summary { fields["summary"] = .string(String(summary.prefix(Self.summaryLimit))) }
        return fields
    }

    /// What the previous turn said, the work in the tree against where the thread started (bounded, cut with a note) and
    /// the untracked files, with what `turn.started` records about them.
    func codexContinuationContext(worktree: URL, base: String) async -> CodexContinuation {
        let events = (try? EventLogReader.read(at: project.eventsURL(threadID)))?.events ?? []
        let summary = events.last { $0.kind == .turnEnded && $0.data["summary"] != nil }?.data["summary"]?.stringValue
        // This runs on the host, outside Codex's sandbox, on files Codex may have changed: no external diff and no text
        // conversion, so a converter a gitattributes line selects is never started.
        var diff: String?
        var cut = false
        let changes = ["diff", "--no-ext-diff", "--no-textconv", "--no-color", base]
        if let result = try? await git.run(changes, in: worktree), result.succeeded {
            let all = result.stdout
            cut = all.utf8.count > Self.continuationDiffLimit
            diff = cut ? String(decoding: all.utf8.prefix(Self.continuationDiffLimit), as: UTF8.self) : all
        }
        var untracked: [String] = []
        var untrackedKnown = false
        if let others = try? await git.run(["ls-files", "--others", "--exclude-standard"], in: worktree), others.succeeded {
            untrackedKnown = true
            untracked = others.stdout.split(separator: "\n").map(String.init).prefix(Self.continuationUntrackedLimit).map { $0 }
        }
        // A git that failed is not an empty tree: the prompt and the record say the changes could not be read.
        let readable = diff != nil && untrackedKnown
        let info: JSONValue = [
            "mode": "fresh_with_context", "diff_bytes": .int(diff?.utf8.count ?? 0), "truncated": .bool(cut),
            "summary": .bool(summary != nil), "untracked": .int(untracked.count), "changes_read": .bool(readable),
        ]
        return CodexContinuation(
            summary: summary, diff: readable ? diff : nil, diffCut: cut, untracked: untracked, info: info)
    }
}

struct CodexContinuation {
    var summary: String?
    /// Nil when git could not be asked: unknown, not "no changes".
    var diff: String?
    var diffCut: Bool
    var untracked: [String]
    var info: JSONValue
}

extension ThreadRunner {
    /// The session a coding turn may resume. The log names the session of the latest turn and the provider that made
    /// it; `session.json` only says whether that id was confirmed, and is ignored for any other id. A handle made
    /// by another provider is never resumed: the turn starts a fresh session.
    static func resumableSession(
        store: ThreadStore, threadID: String, provider: AgentProviderID
    ) -> ThreadStore.Session? {
        let file = store.session(of: threadID)
        let state = store.state(of: threadID)
        // Only a Claude session id (a UUID) can be resumed; the file may be missing or unreadable.
        if let logged = state.sessionID, UUID(uuidString: logged) != nil {
            guard (state.sessionProvider ?? "claude") == "\(provider)" else { return nil }
            let confirmed = file?.sessionID == logged && file?.confirmed == true
            return ThreadStore.Session(sessionID: logged, confirmed: confirmed, provider: "\(provider)")
        }
        guard let file, (file.provider ?? "claude") == "\(provider)" else { return nil }
        return file
    }
}

extension ThreadRunner {
    /// The commit the worktree was cut from: what `worktree.created` recorded, or for a thread that
    /// predates that event the point its branch left `base`.
    func recordedBaseCommit(goal: Goal) async -> String? {
        if let contents = try? EventLogReader.read(at: project.eventsURL(threadID)),
            let event = contents.events.last(where: { $0.kind == .worktreeCreated }),
            let sha = event.data["base_commit"]?.stringValue {
            return sha
        }
        let result = try? await git.run(
            ["merge-base", WorktreeManager.branch(for: threadID), goal.base], in: project.root)
        guard let result, result.succeeded else { return nil }
        let sha = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return sha.isEmpty ? nil : sha
    }
}
