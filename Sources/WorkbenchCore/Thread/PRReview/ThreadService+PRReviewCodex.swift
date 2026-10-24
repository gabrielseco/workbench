import Foundation

extension ThreadService {
    static func codexMissing(_ path: String) -> String { "`\(path)` was not found: install Codex or put it on PATH" }

    /// What the reviewer is asked and bounded by: read-only, timeout-only (Codex has no dollar cap), its answer in
    /// the round's folder beside the checkout, never inside it.
    func reviewRequest(_ round: PRReviewRound, proof: [String]) -> AgentRequest {
        AgentRequest(
            provider: .codex, prompt: PRReview.instruction(brief: round.paths.brief.path),
            images: proof.map { URL(fileURLWithPath: $0) }, workingDirectory: round.paths.tree,
            outputDirectory: round.paths.folder, policy: .readOnlyEvidence, spend: .timeoutOnly, purpose: .review,
            environment: round.settings.environment,
            limits: AgentLimits(
                timeout: round.settings.timeout, maxLineBytes: 1 << 20, maxOutputBytes: PRReview.transcriptLimit),
            answerFile: round.paths.answer)
    }

    /// Runs the reviewer up to `attempts` times while it answers that its model is at capacity.
    func runCodex(
        _ provider: CodexProvider, request: AgentRequest, round: PRReviewRound,
        attach: @Sendable (AgentExecution) -> Void
    ) async -> (text: String, problem: String?) {
        var transcript = ""
        for attempt in 1...PRReview.attempts {
            if round.settings.stopRequested() { return (transcript, "the review was stopped") }
            try? FileManager.default.removeItem(at: round.paths.answer)
            let recorder = TranscriptRecorder()
            let execution: AgentExecution
            do { execution = try AgentRunner.start(provider: provider, request: request, recorder: recorder) } catch {
                guard let failure = error as? AgentFailure else { return (transcript, "codex could not be started: \(error)") }
                let missing = failure.kind == .missingExecutable
                return (transcript, missing ? Self.codexMissing(round.settings.codexPath) : failure.message)
            }
            attach(execution)
            let completion = await execution.completion
            let tail = completion.process.stderrTail
            transcript += "--- attempt \(attempt) ---\n" + recorder.lines.joined(separator: "\n")
            transcript += "\n--- stderr (end) ---\n" + tail + "\n"
            if completion.failure?.kind == .capacity {
                if attempt < PRReview.attempts {
                    let stopped = await Self.sleep(round.settings.capacityBackoff(attempt), stop: round.settings.stopRequested)
                    if stopped { return (transcript, "the review was stopped") }
                    continue
                }
                return (transcript, "codex's model was at capacity \(PRReview.attempts) times; no review. Try again later.")
            }
            return (transcript, Self.codexProcessProblem(completion.process, timeout: round.settings.timeout))
        }
        return (transcript, "codex did not answer")
    }
}

/// Keeps a run's stdout lines, in order, as the transcript the person can read afterwards.
final class TranscriptRecorder: AgentRecorder, @unchecked Sendable {
    private let lock = NSLock()
    private var kept: [String] = []

    var lines: [String] { lock.withLock { kept } }

    func record(_ line: AgentRawLine, activity: [AgentActivity]) async throws {
        guard case .line(let text) = line else { return }
        lock.withLock { kept.append(text) }
    }
}
