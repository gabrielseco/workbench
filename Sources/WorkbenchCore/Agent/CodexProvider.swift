import Foundation

/// The Codex adapter, for read-only evidence work (the automated review). Codex has no dollar cap and cannot confine
/// reads (docs/plan/P9-capabilities.md), so a request is timeout-only and the limit is stated in `capabilities`.
/// It is never used to code: that needs its own confinement probes.
public struct CodexProvider: AgentProvider {
    /// `codex` by name (looked up on PATH) or by path.
    public var executable: String

    public init(executable: String = "codex") { self.executable = executable }

    public var id: AgentProviderID { .codex }

    public var capabilities: AgentCapabilities {
        AgentCapabilities(
            policies: [.readOnlyEvidence], resume: .none, streamsActivity: false, imageAttachments: true,
            structuredOutput: false, reportsUsage: false, hardDollarCap: false, confinesReads: false)
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
        guard request.session == .none else { throw refuse("Codex review keeps no conversation.") }
        guard request.grants.isEmpty else { throw refuse("A read-only call takes no extra permissions.") }
        guard request.model == nil else { throw refuse("Choosing a Codex model is not supported yet.") }
        guard let answer = request.answerFile,
            answer.deletingLastPathComponent().standardizedFileURL.path == request.outputDirectory.standardizedFileURL.path
        else { throw refuse("Codex writes its answer to a file in the output directory, outside the checkout.") }

        // The rules and approval settings of the user's own Codex setup can let a command the sandbox refused run
        // outside it (P9 task 1: `git push` went through `-s read-only`): rules are ignored, nothing is approved.
        // `-i` takes a list of files, so without `--` the prompt would be read as one more image.
        let args =
            ["exec", "-s", "read-only", "-C", request.workingDirectory.path, "--color", "never", "--ephemeral"]
            + ["-o", answer.path, "--ignore-rules", "-c", "approval_policy=\"never\""]
            + request.images.flatMap { ["-i", $0.path] } + ["--", request.prompt]
        return AgentInvocation(
            executable: executable, arguments: args, environment: Self.environment(from: request.environment),
            displayArguments: Array(args[..<(args.firstIndex(of: "--") ?? args.count)]), answerFile: answer)
    }

    public func makeDecoder(for request: AgentRequest) -> any AgentDecoder {
        CodexDecoder(answerFile: request.answerFile)
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
