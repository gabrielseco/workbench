import Foundation

/// A running agent: ordered activity, then exactly one completion. Built only by `AgentRunner.start`.
public final class AgentExecution: Sendable {
    /// Normalized activity, bounded by `AgentLimits.maxBufferedActivity`. Reading it is optional: the child is
    /// never held up by a consumer that does not.
    public let activity: AsyncStream<AgentActivity>
    private let run: ProcessRun
    private let task: Task<AgentCompletion, Never>
    private let gate: AsyncStream<Void>.Continuation

    fileprivate init(
        run: ProcessRun, activity: AsyncStream<AgentActivity>, task: Task<AgentCompletion, Never>,
        gate: AsyncStream<Void>.Continuation
    ) {
        self.run = run
        self.activity = activity
        self.task = task
        self.gate = gate
    }

    /// Starts reading the child's output. Only needed after `start(held: true)`, which lets the caller write what
    /// must come first (the log's `turn.started`, with the pid) before any line is recorded. Output waits in the
    /// pipe layer meanwhile. Idempotent.
    public func begin() {
        gate.yield(())
        gate.finish()
    }

    public var pid: Int32 { run.pid }

    /// Ends when the child has ended and its pipes are drained; the same value however often it is awaited.
    public var completion: AgentCompletion {
        get async { await task.value }
    }

    /// SIGTERM now, SIGKILL and a sweep of descendants after the grace period. Idempotent.
    public func stop() {
        run.stop()
        begin()  // a held execution that is stopped must still end
    }
}

public enum AgentRunner {
    /// Validates, resolves the executable, spawns, and returns at once. A refusal or a failed launch throws an
    /// `AgentFailure` before any handle exists; the caller records it as a failed attempt, not as a process.
    public static func start(
        provider: any AgentProvider, request: AgentRequest, recorder: (any AgentRecorder)? = nil, held: Bool = false
    ) throws -> AgentExecution {
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
        spawn.killGrace = request.limits.killGrace
        let process: ProcessRun
        do {
            process = try ProcessRunner.start(spawn)
        } catch {
            throw AgentFailure(.process, "The process did not start: \(error)", retry: .never, diagnostic: "\(error)")
        }

        let (stream, continuation) = AsyncStream.makeStream(
            of: AgentActivity.self, bufferingPolicy: .bufferingNewest(max(1, request.limits.maxBufferedActivity)))
        let decoder = provider.makeDecoder(for: request)
        let limits = request.limits
        let (gate, gateContinuation) = AsyncStream.makeStream(of: Void.self)
        if !held { gateContinuation.finish() }
        let task = Task.detached {
            var open = gate.makeAsyncIterator()
            _ = await open.next()
            return await drive(
                process, decoder: decoder, limits: limits, continuation: continuation, recorder: recorder)
        }
        return AgentExecution(run: process, activity: stream, task: task, gate: gateContinuation)
    }

    private static func drive(
        _ process: ProcessRun, decoder initial: any AgentDecoder, limits: AgentLimits,
        continuation: AsyncStream<AgentActivity>.Continuation, recorder: (any AgentRecorder)?
    ) async -> AgentCompletion {
        var decoder = initial
        var recordingFailure: String?
        func record(_ line: AgentRawLine, _ items: [AgentActivity]) async {
            guard let recorder, recordingFailure == nil else { return }
            do { try await recorder.record(line, activity: items) } catch {
                recordingFailure = "\(error)"
                process.stop()
            }
        }
        var dropped = 0
        var oversized = 0
        func emit(_ item: AgentActivity) {
            if case .dropped = continuation.yield(item) { dropped += 1 }
        }

        var exit: ProcessExit?
        for await event in process.events {
            switch event {
            case .started(let pid):
                emit(.started(pid: pid))
            case .line(let line):
                let items = decoder.consume(line: line)
                for item in items { emit(item) }
                await record(.line(line), items)
            case .oversizedLine(let preview, let total):
                oversized += 1
                emit(.diagnostic("A line of \(total) bytes was over the limit; kept the first \(preview.utf8.count)."))
                let items = decoder.consume(oversizedPreview: preview, totalBytes: total)
                for item in items { emit(item) }
                await record(.oversized(preview: preview, totalBytes: total), items)
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
                droppedActivity: dropped, outputTruncated: false, oversizedLines: oversized,
                recordingFailure: recordingFailure)
        }

        let result = decoder.finish(exit: exit)
        if let late = result.lateLine { await record(.late(late), []) }
        let failure = failure(exit, provider: result.failure, limits: limits)
        continuation.finish()
        return AgentCompletion(
            process: exit, provider: result.outcome, answer: result.answer, session: result.session,
            usage: result.usage, failure: failure, droppedActivity: dropped, outputTruncated: exit.outputTruncated,
            oversizedLines: oversized, permissionDenials: result.permissionDenials,
            permissionDenialCount: result.permissionDenialCount, recordingFailure: recordingFailure)
    }

    /// A stop or a deadline is what happened, whatever the provider printed before it: it keeps the provider's
    /// message as its diagnostic and is never retried as, say, a capacity failure. Otherwise the provider's own
    /// explanation wins over the exit status.
    private static func failure(_ exit: ProcessExit, provider: AgentFailure?, limits: AgentLimits) -> AgentFailure? {
        guard exit.cause != .natural else { return provider ?? processFailure(exit, limits: limits) }
        var failure = processFailure(exit, limits: limits)
        if let provider { failure?.diagnostic = "\(provider.kind.rawValue): \(provider.message)" }
        return failure
    }

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
        return text.isEmpty ? "" : " stderr: " + String(text.suffix(min(max(0, limits.maxRawBytes), 512)))
    }
}
