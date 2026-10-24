import Foundation

/// The Codex adapter: read-only evidence work (judge, review, goal drafting) and, built but not yet selectable by
/// `run`, scoped coding. Codex has no dollar cap and cannot confine reads (docs/plan/P9-capabilities.md), so a request
/// is timeout-only and the limit is stated in `capabilities`.
public struct CodexProvider: AgentProvider {
    /// `codex` by name (looked up on PATH) or by path.
    public var executable: String

    public init(executable: String = "codex") { self.executable = executable }

    public var id: AgentProviderID { .codex }

    public var capabilities: AgentCapabilities {
        AgentCapabilities(
            policies: [.readOnlyEvidence, .scopedCoding], resume: .none, streamsActivity: true, imageAttachments: true,
            structuredOutput: false, reportsUsage: true, hardDollarCap: false, confinesReads: false)
    }

    /// The variables Codex runs with: the fixed minimal set plus its own login and configuration. Nothing of the
    /// project's `env_pass`, and no other provider's credentials.
    static let environmentNames: Set<String> = [
        "PATH", "HOME", "USER", "LOGNAME", "SHELL", "LANG", "TMPDIR", "TERM", "CODEX_HOME", "OPENAI_API_KEY",
    ]

    static func environment(from parent: [String: String]) -> [String: String] {
        parent.filter {
            environmentNames.contains($0.key) || $0.key.hasPrefix("LC_") || $0.key.hasPrefix("CODEX_")
                || $0.key.hasPrefix("OPENAI_")
        }
    }

    public func invocation(for request: AgentRequest) throws -> AgentInvocation {
        func refuse(_ why: String) -> AgentFailure { AgentFailure(.unsupportedCapability, why, retry: .afterFix) }
        guard request.spend == .timeoutOnly else {
            throw refuse("Codex cannot enforce a dollar limit; its requests are timeout-only.")
        }
        if request.policy == .scopedCoding { return try codingInvocation(for: request) }
        guard request.session == .none else { throw refuse("Codex review keeps no conversation.") }
        guard request.grants.isEmpty else { throw refuse("A read-only call takes no extra permissions.") }
        guard let answer = request.answerFile,
            answer.deletingLastPathComponent().standardizedFileURL.path == request.outputDirectory.standardizedFileURL.path
        else { throw refuse("Codex writes its answer to a file in the output directory, outside the checkout.") }

        // The rules and approval settings of the user's own Codex setup can let a command the sandbox refused run
        // outside it (P9 task 1: `git push` went through `-s read-only`): rules are ignored, nothing is approved.
        // `-i` takes a list of files, so without `--` the prompt would be read as one more image.
        // A model and an effort are set here or Codex uses `~/.codex/config.toml`, which may be low effort.
        let chosen =
            (request.model.map { ["-m", $0] } ?? [])
            + (request.reasoningEffort.map { ["-c", "model_reasoning_effort=\"\($0)\""] } ?? [])
        let args =
            ["exec", "-s", "read-only", "-C", request.workingDirectory.path, "--color", "never", "--ephemeral"] + chosen
            + ["-o", answer.path, "--ignore-rules", "-c", "approval_policy=\"never\""]
            + request.images.flatMap { ["-i", $0.path] } + ["--", request.prompt]
        return AgentInvocation(
            executable: executable, arguments: args, environment: Self.environment(from: request.environment),
            displayArguments: Array(args[..<(args.firstIndex(of: "--") ?? args.count)]), answerFile: answer)
    }

    /// A coding turn: edits inside the worktree, nothing outside it, no network, and nothing the user's own Codex
    /// setup could approve or allow (their config and exec-policy rules are ignored, nothing is asked). `.git` is
    /// read-only under `workspace-write`, so the agent cannot commit; `accept` commits what is pending. No native
    /// resume (`codex exec resume` takes no `-s` or `-C`), so the turn is one-shot and writes no session file.
    private func codingInvocation(for request: AgentRequest) throws -> AgentInvocation {
        func refuse(_ why: String) -> AgentFailure { AgentFailure(.unsupportedCapability, why, retry: .afterFix) }
        guard request.session == .none else {
            throw refuse("Codex coding keeps no conversation yet: each turn is a fresh process with prepared context.")
        }
        guard request.grants.isEmpty else { throw refuse("Extra tool permissions are Claude's patterns; Codex takes none.") }
        guard request.images.isEmpty else { throw refuse("Images in a Codex coding turn are not supported yet.") }
        guard request.workingDirectory.path.hasPrefix("/") else {
            throw refuse("A coding turn needs the worktree's absolute path.")
        }
        var args = ["exec", "--json", "--color", "never", "--skip-git-repo-check", "--ephemeral"]
        if let model = request.model { args += ["-m", model] }
        if let effort = request.reasoningEffort { args += ["-c", "model_reasoning_effort=\"\(effort)\""] }
        args += ["--ignore-user-config", "--ignore-rules", "-c", "approval_policy=\"never\""]
        args += ["-c", "sandbox_workspace_write.network_access=false"]
        // `workspace-write` also makes `$TMPDIR` and `/tmp` writable (P9 task 1: a push to a remote there worked),
        // which would let a turn change another checkout or push from a temporary one.
        args += ["-c", "sandbox_workspace_write.exclude_tmpdir_env_var=true"]
        args += ["-c", "sandbox_workspace_write.exclude_slash_tmp=true"]
        args += ["-s", "workspace-write", "-C", request.workingDirectory.path, "--", request.prompt]
        return AgentInvocation(
            executable: executable, arguments: args, environment: Self.environment(from: request.environment),
            displayArguments: Array(args[..<(args.firstIndex(of: "--") ?? args.count)]))
    }

    public func makeDecoder(for request: AgentRequest) -> any AgentDecoder {
        if request.policy == .scopedCoding {
            return CodexCodingDecoder(purpose: request.purpose, maxRawBytes: request.limits.maxRawBytes)
        }
        return CodexDecoder(answerFile: request.answerFile)
    }
}

/// Reads what a Codex run left: its answer file, and whether it said its model is at capacity. The stream is a
/// transcript for the person, not the answer, so no line of it is decoded.
struct CodexDecoder: AgentDecoder {
    var answerFile: URL?
    private var sawCapacity = false

    init(answerFile: URL?) { self.answerFile = answerFile }

    static func atCapacity(_ text: String) -> Bool { text.lowercased().contains("at capacity") }

    mutating func consume(line: String) -> [AgentActivity] {
        if Self.atCapacity(line) { sawCapacity = true }
        return []
    }

    mutating func consume(oversizedPreview preview: String, totalBytes: Int) -> [AgentActivity] { [] }

    mutating func finish(exit: ProcessExit) -> AgentDecoderResult {
        guard let answerFile, ThreadService.readAnswer(answerFile) != nil else {
            // "At capacity" only explains a run that wrote no answer; one that did is judged by its answer.
            if sawCapacity || Self.atCapacity(exit.stderrTail) {
                return AgentDecoderResult(
                    outcome: .failed,
                    failure: AgentFailure(.capacity, "Codex's model is at capacity.", retry: .transient))
            }
            return AgentDecoderResult(outcome: .unknown)
        }
        var ended = false
        if exit.cause == .natural, case .exited(0) = exit.termination { ended = true }
        return AgentDecoderResult(outcome: ended ? .succeeded : .failed, answer: .file(answerFile))
    }
}
