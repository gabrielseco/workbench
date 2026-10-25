import Foundation

public struct SpawnRequest: Sendable {
    public var executable: URL
    public var arguments: [String]
    /// Exactly what the child sees. Nothing is inherited.
    public var environment: [String: String]
    public var workingDirectory: URL
    /// Wall-clock limit from spawn. Hitting it is a stop with cause `.timedOut`.
    public var timeout: TimeInterval
    /// After SIGTERM, how long to wait before SIGKILL. SIGTERM is what lets `claude` clean up its own tool
    /// children (spike S6), so this is deliberately generous.
    public var killGrace: TimeInterval = 5
    /// After the child exits, how long to wait for its pipes to close before giving up on them. A
    /// grandchild that kept them open must not keep the turn open.
    public var drainGrace: TimeInterval = 1
    /// How often the descendant set is refreshed while running. A tool child that outlives a crashed
    /// parent can only be found if it was seen before the parent died.
    public var snapshotInterval: TimeInterval = 0.1
    public var maxLineBytes: Int = 1 << 20
    /// Total stdout kept per turn. Past it lines are dropped (only the last one is remembered) and the
    /// pipe is still drained, so the child never blocks.
    public var maxOutputBytes: Int = 64 << 20

    public init(
        executable: URL, arguments: [String], environment: [String: String], workingDirectory: URL,
        timeout: TimeInterval
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.timeout = timeout
    }
}

public enum StopCause: Equatable, Sendable {
    /// Nobody asked it to stop.
    case natural
    case stopped
    case timedOut
}

public struct ProcessExit: Equatable, Sendable {
    public var termination: Termination
    public var cause: StopCause
    public var durationMs: Int
    /// SIGKILL was needed because SIGTERM did not end it within `killGrace`.
    public var escalatedToKill: Bool
    /// Descendants still alive when the child ended, killed by the sweep.
    public var sweptProcesses: Int
    public var outputTruncated: Bool
    /// When `outputTruncated`, the last complete stdout line seen (normally the `result` line).
    public var lastLineAfterLimit: String?
    /// The end of stderr, at most 16 KiB.
    public var stderrTail: String
    /// The pipes did not close within `drainGrace` after exit.
    public var drainTimedOut: Bool
}

public enum ProcessEvent: Equatable, Sendable {
    case started(pid: Int32)
    case line(String)
    /// A line over `maxLineBytes`: its start and its real size. The rest was dropped.
    case oversizedLine(preview: String, totalBytes: Int)
    /// Always the last event, exactly once, however the child ended.
    case exited(ProcessExit)
}

public final class ProcessRun: @unchecked Sendable {
    /// Lines in order, then one `.exited`. Dropping or cancelling the iteration stops the child.
    public let events: AsyncStream<ProcessEvent>
    public let pid: Int32
    private let engine: ProcessEngine

    fileprivate init(engine: ProcessEngine, events: AsyncStream<ProcessEvent>, pid: Int32) {
        self.engine = engine
        self.events = events
        self.pid = pid
    }

    /// SIGTERM now, SIGKILL (and a sweep of descendants) after `killGrace`. Idempotent.
    public func stop() { engine.requestStop(.stopped) }

    /// Ends the child exactly as its timeout would (cause `.timedOut`, same SIGTERM then SIGKILL), now. For tests that
    /// need a hang ended once the child is known to be running, instead of a timer sized to outlast a loaded runner.
    public func expire() { engine.requestStop(.timedOut) }

    /// Descendants seen so far that may still be running. For tests and diagnostics.
    public func trackedDescendants() -> [Int32] { engine.trackedPIDs() }
}

public enum ProcessRunner {
    /// Starts the child and returns at once. All reading and signalling happens off the caller's thread.
    public static func start(_ request: SpawnRequest) throws -> ProcessRun {
        try ProcessEngine.launch(request)
    }
}

// MARK: - Engine

/// Owns one child from spawn to its terminal event. Every piece of state is confined to `queue`.
private final class ProcessEngine: @unchecked Sendable {
    private static let stderrTailBytes = 16 << 10

    private let request: SpawnRequest
    private let queue = DispatchQueue(label: "workbench.process")
    private let continuation: AsyncStream<ProcessEvent>.Continuation
    private let startedAt = DispatchTime.now()

    private var pid: pid_t = 0
    private var watcher: ChildExitWatcher?
    private var stdoutSource: (any PipeReader)?
    private var stderrSource: (any PipeReader)?
    private var stdoutOpen = false
    private var stderrOpen = false
    private var timeoutTimer: DispatchSourceTimer?
    private var escalationTimer: DispatchSourceTimer?
    private var snapshotTimer: DispatchSourceTimer?
    private var drainTimer: DispatchSourceTimer?

    private var splitter: LineSplitter
    private var readBuffer = [UInt8](repeating: 0, count: 64 << 10)
    private var emittedBytes = 0
    private var outputTruncated = false
    private var lastLine: String?
    private var stderrTail = Data()

    private var cause: StopCause = .natural
    private var terminating = false
    private var childExited = false
    private var escalated = false
    private var swept = 0
    private var drainTimedOut = false
    private var termination: Termination = .lost
    private var tracked = Set<ProcessMember>()
    private var finished = false

    private init(request: SpawnRequest, continuation: AsyncStream<ProcessEvent>.Continuation) {
        self.request = request
        self.continuation = continuation
        self.splitter = LineSplitter(maxLineBytes: request.maxLineBytes)
    }

    static func launch(_ request: SpawnRequest) throws -> ProcessRun {
        var continuation: AsyncStream<ProcessEvent>.Continuation!
        let events = AsyncStream<ProcessEvent>(bufferingPolicy: .unbounded) { continuation = $0 }
        let engine = ProcessEngine(request: request, continuation: continuation)
        try engine.spawn()
        continuation.onTermination = { [engine] _ in engine.requestStop(.stopped) }
        return ProcessRun(engine: engine, events: events, pid: engine.pid)
    }

    // MARK: Start

    private func spawn() throws {
        var out: [Int32] = [0, 0]
        var err: [Int32] = [0, 0]
        guard pipe(&out) == 0 else { throw SpawnError.launchFailed("pipe: \(String(cString: strerror(errno)))") }
        guard pipe(&err) == 0 else {
            close(out[0]); close(out[1])
            throw SpawnError.launchFailed("pipe: \(String(cString: strerror(errno)))")
        }
        for fd in out + err { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }

        do {
            pid = try Spawner.spawn(
                executable: request.executable.path, arguments: request.arguments,
                environment: request.environment, workingDirectory: request.workingDirectory.path,
                stdout: out[1], stderr: err[1])
        } catch {
            for fd in out + err { close(fd) }
            throw error
        }
        // The child has its own copies. Ours must go, or the pipes would never reach EOF.
        close(out[1])
        close(err[1])
        for fd in [out[0], err[0]] {
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        }

        queue.sync {
            stdoutOpen = true
            stderrOpen = true
            stdoutSource = makeReader(fd: out[0], isStdout: true)
            stderrSource = makeReader(fd: err[0], isStdout: false)
            continuation.yield(.started(pid: pid))

            watcher = ChildExitWatcher(pid: pid, queue: queue) { [self] in childDidExit() }

            timeoutTimer = makeTimer(after: request.timeout) { [self] in beginTermination(.timedOut) }
            snapshotTimer = makeTimer(after: request.snapshotInterval, repeating: request.snapshotInterval) { [self] in
                refreshTracked()
            }
        }
    }

    // MARK: Reading

    private func makeReader(fd: Int32, isStdout: Bool) -> any PipeReader {
        platform.watch(fd: fd, queue: queue) { [self] in readAvailable(fd: fd, isStdout: isStdout) }
    }

    private func readAvailable(fd: Int32, isStdout: Bool) {
        while true {
            let count = readBuffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                let chunk = Data(readBuffer[0..<count])
                if isStdout { handleStdout(chunk) } else { handleStderr(chunk) }
            } else if count == 0 {
                readerReachedEOF(isStdout: isStdout)
                return
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN {
                return
            } else {
                readerReachedEOF(isStdout: isStdout)
                return
            }
        }
    }

    private func handleStdout(_ chunk: Data) {
        splitter.feed(chunk) { output in
            switch output {
            case .line(let data):
                let text = String(decoding: data, as: UTF8.self)
                lastLine = text
                guard !outputTruncated else { return }
                emittedBytes += data.count + 1
                if emittedBytes > request.maxOutputBytes {
                    outputTruncated = true
                    return
                }
                continuation.yield(.line(text))
            case .oversized(let preview, let total):
                guard !outputTruncated else { return }
                emittedBytes += preview.count + 1
                continuation.yield(
                    .oversizedLine(preview: String(decoding: preview, as: UTF8.self), totalBytes: total))
            }
        }
    }

    private func handleStderr(_ chunk: Data) {
        stderrTail.append(chunk)
        if stderrTail.count > Self.stderrTailBytes {
            stderrTail = Data(stderrTail.suffix(Self.stderrTailBytes))
        }
    }

    private func readerReachedEOF(isStdout: Bool) {
        if isStdout {
            guard stdoutOpen else { return }
            stdoutOpen = false
            splitter.finish { output in
                // A last line with no newline is still a line.
                if case .line(let data) = output {
                    let text = String(decoding: data, as: UTF8.self)
                    lastLine = text
                    if !outputTruncated { continuation.yield(.line(text)) }
                } else if case .oversized(let preview, let total) = output, !outputTruncated {
                    continuation.yield(
                        .oversizedLine(preview: String(decoding: preview, as: UTF8.self), totalBytes: total))
                }
            }
            stdoutSource?.cancel()
            stdoutSource = nil
        } else {
            guard stderrOpen else { return }
            stderrOpen = false
            stderrSource?.cancel()
            stderrSource = nil
        }
        finishIfDrained()
    }

    // MARK: Stopping

    func requestStop(_ why: StopCause) {
        queue.async { [self] in beginTermination(why) }
    }

    private func beginTermination(_ why: StopCause) {
        guard !finished, !childExited, !terminating else { return }
        terminating = true
        cause = why
        refreshTracked()
        killpg(pid, SIGTERM)
        kill(pid, SIGTERM)
        escalationTimer = makeTimer(after: request.killGrace) { [self] in escalate() }
    }

    private func escalate() {
        guard !finished, !childExited else { return }
        escalated = true
        // Descendants first, while they can still be found by their parent: once `claude` dies they are
        // re-parented and a tree walk no longer reaches them.
        refreshTracked()
        killTracked()
        killpg(pid, SIGKILL)
        kill(pid, SIGKILL)
    }

    private func refreshTracked() {
        guard !finished, !childExited else { return }
        for member in ProcessTree.descendants(of: pid) { tracked.insert(member) }
    }

    /// SIGKILL every tracked descendant that is still the same process, deepest first.
    @discardableResult
    private func killTracked() -> Int {
        var count = 0
        for member in tracked.sorted(by: { ($0.startSeconds, $0.startMicros) > ($1.startSeconds, $1.startMicros) })
        where ProcessTree.isAlive(member) {
            kill(member.pid, SIGKILL)
            count += 1
        }
        return count
    }

    func trackedPIDs() -> [Int32] {
        queue.sync { tracked.map(\.pid).sorted() }
    }

    // MARK: Ending

    private func childDidExit() {
        guard !finished, !childExited else { return }
        childExited = true
        timeoutTimer?.cancel(); timeoutTimer = nil
        escalationTimer?.cancel(); escalationTimer = nil
        snapshotTimer?.cancel(); snapshotTimer = nil

        // The child is a zombie until reaped, so its pid (and process group id) is still ours alone.
        swept = killTracked()
        killpg(pid, SIGKILL)
        termination = watcher?.reap() ?? .lost
        watcher = nil

        if stdoutOpen || stderrOpen {
            drainTimer = makeTimer(after: request.drainGrace) { [self] in
                drainTimedOut = true
                if stdoutOpen { readerReachedEOF(isStdout: true) }
                if stderrOpen { readerReachedEOF(isStdout: false) }
                finish()
            }
        } else {
            finish()
        }
    }

    private func finishIfDrained() {
        if childExited, !stdoutOpen, !stderrOpen { finish() }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        for timer in [timeoutTimer, escalationTimer, snapshotTimer, drainTimer] { timer?.cancel() }
        timeoutTimer = nil; escalationTimer = nil; snapshotTimer = nil; drainTimer = nil
        watcher?.cancel(); watcher = nil
        stdoutSource?.cancel(); stdoutSource = nil
        stderrSource?.cancel(); stderrSource = nil

        let elapsed = DispatchTime.now().uptimeNanoseconds - startedAt.uptimeNanoseconds
        continuation.yield(
            .exited(
                ProcessExit(
                    termination: termination, cause: cause, durationMs: Int(elapsed / 1_000_000),
                    escalatedToKill: escalated, sweptProcesses: swept, outputTruncated: outputTruncated,
                    lastLineAfterLimit: outputTruncated ? lastLine : nil,
                    stderrTail: String(decoding: stderrTail, as: UTF8.self), drainTimedOut: drainTimedOut)))
        continuation.finish()
    }

    // MARK: Timers

    private func makeTimer(
        after delay: TimeInterval, repeating interval: TimeInterval? = nil,
        handler: @escaping @Sendable () -> Void
    ) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + delay, repeating: interval ?? .infinity)
        timer.setEventHandler(handler: handler)
        timer.resume()
        return timer
    }
}
