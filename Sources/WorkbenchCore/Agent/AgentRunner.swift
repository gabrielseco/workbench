import Foundation

/// A running agent: ordered activity, then exactly one completion. Built only by `AgentRunner.start`.
public final class AgentExecution: Sendable {
    /// Normalized activity, bounded by `AgentLimits.maxBufferedActivity`. Reading it is optional: the child is
    /// never held up by a consumer that does not.
    public let activity: AsyncStream<AgentActivity>
    private let run: ProcessRun
    private let task: Task<AgentCompletion, Never>

    fileprivate init(run: ProcessRun, activity: AsyncStream<AgentActivity>, task: Task<AgentCompletion, Never>) {
        self.run = run
        self.activity = activity
        self.task = task
    }

    public var pid: Int32 { run.pid }

    /// Ends when the child has ended and its pipes are drained; the same value however often it is awaited.
    public var completion: AgentCompletion {
        get async { await task.value }
    }

    /// SIGTERM now, SIGKILL and a sweep of descendants after the grace period. Idempotent.
    public func stop() { run.stop() }
}

public enum AgentRunner {
    /// Validates, resolves the executable, spawns, and returns at once. A refusal or a failed launch throws an
    /// `AgentFailure` before any handle exists; the caller records it as a failed attempt, not as a process.
    public static func start(provider: any AgentProvider, request: AgentRequest) throws -> AgentExecution {
        if let refusal = request.validate(against: provider) { throw refusal }
        let invocation = try provider.invocation(for: request)

        guard
            let executable = ExecutableResolver.resolve(
                invocation.executable, searchPath: invocation.environment["PATH"])
        else {
            throw AgentFailure(
                .missingExecutable, "Could not find \"\(invocation.executable)\" on PATH. Install it or set its path.",
                retry: .afterFix)
        }

        var spawn = SpawnRequest(
            executable: executable, arguments: invocation.arguments, environment: invocation.environment,
            workingDirectory: request.workingDirectory, timeout: request.limits.timeout)
        spawn.maxLineBytes = request.limits.maxLineBytes
        spawn.maxOutputBytes = request.limits.maxOutputBytes
        let process: ProcessRun
        do {
            process = try ProcessRunner.start(spawn)
        } catch {
            throw AgentFailure(.process, "The process did not start: \(error)", retry: .never)
        }

        let (stream, continuation) = AsyncStream.makeStream(
            of: AgentActivity.self, bufferingPolicy: .bufferingNewest(max(1, request.limits.maxBufferedActivity)))
        let decoder = provider.makeDecoder(for: request)
        let limits = request.limits
        let task = Task.detached { await drive(process, decoder: decoder, limits: limits, continuation: continuation) }
        return AgentExecution(run: process, activity: stream, task: task)
    }

    private static func drive(
        _ process: ProcessRun, decoder initial: any AgentDecoder, limits: AgentLimits,
        continuation: AsyncStream<AgentActivity>.Continuation
    ) async -> AgentCompletion {
        var decoder = initial
        var dropped = 0
        func emit(_ item: AgentActivity) {
            if case .dropped = continuation.yield(item) { dropped += 1 }
        }

        var exit: ProcessExit?
        for await event in process.events {
            switch event {
            case .started(let pid):
                emit(.started(pid: pid))
            case .line(let line):
                for item in decoder.consume(line: line) { emit(item) }
            case .oversizedLine(let preview, let total):
                emit(.diagnostic("A line of \(total) bytes was over the limit; kept the first \(preview.utf8.count)."))
            case .exited(let e):
                exit = e
            }
        }
        // `.exited` is always the last event; its absence is a bug in the process layer, reported, not hidden.
        guard let exit else {
            continuation.finish()
            return AgentCompletion(
                process: ProcessExit(
                    termination: .lost, cause: .natural, durationMs: 0, escalatedToKill: false, sweptProcesses: 0,
                    outputTruncated: false, lastLineAfterLimit: nil, stderrTail: "", drainTimedOut: false),
                provider: .unknown, answer: nil, session: nil, usage: nil,
                failure: AgentFailure(.interrupted, "The process ended with no exit record.", retry: .never),
                droppedActivity: dropped, outputTruncated: false)
        }

        let result = decoder.finish(exit: exit)
        let failure = result.failure ?? processFailure(exit, limits: limits)
        continuation.finish()
        return AgentCompletion(
            process: exit, provider: result.outcome, answer: result.answer, session: result.session,
            usage: result.usage, failure: failure, droppedActivity: dropped, outputTruncated: exit.outputTruncated)
    }

    /// Process-level causes the provider's output cannot explain. A provider's own failure wins: it says why.
    private static func processFailure(_ exit: ProcessExit, limits: AgentLimits) -> AgentFailure? {
        switch exit.cause {
        case .timedOut:
            return AgentFailure(
                .timeout, "Ended at the \(Int(limits.timeout)) s limit.", retry: .never, diagnostic: nil)
        case .stopped:
            return AgentFailure(.cancellation, "Stopped on request.", retry: .never)
        case .natural:
            break
        }
        switch exit.termination {
        case .exited(0):
            return nil
        case .exited(let code):
            return AgentFailure(
                .process, "Exited with status \(code).\(tail(exit.stderrTail, limits))", retry: .never)
        case .signaled(let signal):
            return AgentFailure(.process, "Ended by signal \(signal).\(tail(exit.stderrTail, limits))", retry: .never)
        case .lost:
            return AgentFailure(.process, "Its exit status was lost.", retry: .never)
        }
    }

    private static func tail(_ stderr: String, _ limits: AgentLimits) -> String {
        let text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "" : " stderr: " + String(text.suffix(min(limits.maxRawBytes, 512)))
    }
}
