import Foundation

extension ThreadService {
    static func agentMissing(_ executable: String, provider: AgentProviderID) -> String {
        "`\(executable)` was not found: install \(provider == .codex ? "Codex" : "Claude Code") or put it on PATH"
    }

    /// What the reviewer is asked and bounded by: read-only, its answer in the round's folder beside the checkout,
    /// never inside it. Codex works inside the checkout and writes its answer to a file; Claude has only `Read`, in
    /// the round's folder (brief, diff and checkout), and its answer text is written to the same file afterwards.
    func reviewRequest(_ round: PRReviewRound, proof: [String]) -> AgentRequest {
        // A refused spend never reaches here as a request that runs: `runRound` refuses it first.
        let capabilities = round.makeProvider()?.capabilities ?? AgentCapabilities(policies: [], resume: .none)
        let spend = (try? round.spend(capabilities: capabilities).get()) ?? .timeoutOnly
        let limits = AgentLimits(
            timeout: round.settings.timeout, maxLineBytes: 1 << 20, maxOutputBytes: PRReview.transcriptLimit)
        let images = proof.map { URL(fileURLWithPath: $0) }
        if round.agent.provider == .claude {
            return AgentRequest(
                provider: .claude, model: round.agent.model,
                prompt: PRReview.instruction(
                    brief: round.paths.brief.lastPathComponent, checkout: round.paths.tree.lastPathComponent),
                images: images, workingDirectory: round.paths.folder, outputDirectory: round.paths.folder,
                policy: .readOnlyEvidence, spend: spend, session: .start(proposed: round.sessionID),
                purpose: .review, environment: round.settings.environment, limits: limits,
                evidenceFiles: [round.paths.brief.lastPathComponent, round.paths.diff.lastPathComponent],
                answerFile: round.paths.answer, reasoningEffort: round.agent.reasoningEffort)
        }
        return AgentRequest(
            provider: round.agent.provider, model: round.agent.model,
            prompt: PRReview.instruction(brief: round.paths.brief.path), images: images,
            workingDirectory: round.paths.tree, outputDirectory: round.paths.folder, policy: .readOnlyEvidence,
            spend: spend, purpose: .review, environment: round.settings.environment, limits: limits,
            answerFile: round.paths.answer, reasoningEffort: round.agent.reasoningEffort)
    }

    /// Runs the reviewer up to `PRReview.attempts` times while it answers that its model is at capacity. A provider that
    /// answers in its output (Claude) has that text written to the round's answer file, so everything after reads one file.
    func runAgent(
        _ provider: any AgentProvider, request: AgentRequest, round: PRReviewRound,
        attach: @Sendable (AgentExecution) -> Void
    ) async -> AgentRunReport {
        var transcript = ""
        var cost: Double?
        let name = round.agent.provider.description
        for attempt in 1...PRReview.attempts {
            if round.settings.stopRequested() {
                return AgentRunReport(text: transcript, problem: "the review was stopped", costUSD: cost)
            }
            try? FileManager.default.removeItem(at: round.paths.answer)
            let recorder = TranscriptRecorder()
            // Each physical start is its own attempt, on record before the process exists; a retry adds no round.
            let attemptID: String?
            do { attemptID = try await round.attempts?.start() } catch {
                let why = "the attempt could not be recorded, so \(name) was not started: \(error)"
                return AgentRunReport(text: transcript, problem: why, costUSD: cost)
            }
            let execution: AgentExecution
            do { execution = try AgentRunner.start(provider: provider, request: request, recorder: recorder) } catch {
                let problem: String
                if let failure = error as? AgentFailure {
                    problem =
                        failure.kind == .missingExecutable
                        ? Self.agentMissing(round.executable, provider: round.agent.provider) : failure.message
                } else {
                    problem = "\(name) could not be started: \(error)"
                }
                if let attemptID {
                    do { try await round.attempts?.end(attemptID, "failed", reason: problem) } catch {
                        return AgentRunReport(text: transcript, problem: "\(problem); \(error)", costUSD: cost)
                    }
                }
                return AgentRunReport(text: transcript, problem: problem, costUSD: cost)
            }
            attach(execution)
            let completion = await execution.completion
            if let attemptID {
                do {
                    try await round.attempts?.end(
                        attemptID, AttemptLog.outcome(of: completion.process, failure: completion.failure))
                } catch { return AgentRunReport(text: transcript, problem: "\(error)", costUSD: cost) }
            }
            if let reported = completion.usage?.costUSD { cost = (cost ?? 0) + reported }
            let tail = completion.process.stderrTail
            transcript += "--- attempt \(attempt) ---\n" + recorder.lines.joined(separator: "\n")
            transcript += "\n--- stderr (end) ---\n" + tail + "\n"
            if completion.failure?.kind == .capacity {
                if attempt < PRReview.attempts {
                    let stopped = await Self.sleep(round.settings.capacityBackoff(attempt), stop: round.settings.stopRequested)
                    if stopped { return AgentRunReport(text: transcript, problem: "the review was stopped", costUSD: cost) }
                    continue
                }
                let tired = "\(name)'s model was at capacity \(PRReview.attempts) times; no review. Try again later."
                return AgentRunReport(text: transcript, problem: tired, costUSD: cost)
            }
            if let problem = Self.processProblem(completion.process, timeout: round.settings.timeout, name: name) {
                return AgentRunReport(text: transcript, problem: problem, costUSD: cost)
            }
            if let failure = completion.failure {
                return AgentRunReport(text: transcript, problem: failure.message, costUSD: cost)
            }
            if let text = completion.summary, let file = request.answerFile {
                try? text.write(to: file, atomically: true, encoding: .utf8)
            }
            return AgentRunReport(text: transcript, problem: nil, costUSD: cost)
        }
        return AgentRunReport(text: transcript, problem: "\(name) did not answer", costUSD: cost)
    }
}

/// What `runAgent` leaves: the transcript, why there is no answer (nil when there is one), the cost the provider reported.
struct AgentRunReport: Sendable {
    var text: String
    var problem: String?
    var costUSD: Double?
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
