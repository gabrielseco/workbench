import Foundation

public enum CheckResult: String, Sendable, Equatable {
    case passed
    case failed
    case timedOut = "timed_out"
    case stopped
    case interrupted
}

public struct CheckReport: Sendable, Equatable {
    public var turn: Int
    public var command: String
    public var result: CheckResult
    public var exitCode: Int32?
    public var signal: Int32?
    public var durationMs: Int
    /// Where the output is, relative to the thread directory.
    public var outputRef: String
    public var outputTruncated: Bool
}

enum CheckError: Error, Equatable, CustomStringConvertible {
    case notFound(String)
    case outputFile(String)

    var description: String {
        switch self {
        case .notFound(let name): "cannot find an executable `\(name)` (in the worktree for a path, else on PATH)"
        case .outputFile(let reason): "cannot write the output file: \(reason)"
        }
    }
}

/// Runs the project's check command once, after a turn, and records it as `check.started` and `check.ran`.
///
/// Bounded exactly as a turn is, because it goes through the same `ProcessRunner`: a timeout, SIGTERM then
/// SIGKILL, the process tree swept, no descriptors inherited.
struct CheckRunner {
    /// Output kept per check. Past it the file ends with a marker line and the command is still drained.
    static let maxOutputBytes = 1 << 20
    /// `ProcessRunner` reads stdout and stderr through separate pipes, which loses the order they were
    /// written in. This fixed script makes them one stream before the command starts. The command's words
    /// arrive as arguments and are never read as shell text; `exec` leaves no shell behind.
    static let mergeStreams = #"exec "$@" 2>&1"#

    var command: String
    var worktree: URL
    var environment: [String: String]
    var timeout: TimeInterval
    var killGrace: TimeInterval

    /// - Parameter attach: called once with the running process, so the caller can stop it.
    func run(
        turn: Int, outputURL: URL, log: EventLogWriter, attach: @Sendable (ProcessRun) async -> Void
    ) async throws -> CheckReport {
        try await log.append(.checkStarted, turn: turn, data: ["command": .string(command)])
        let started = Date()

        var outcome = Outcome()
        do {
            outcome = try await execute(outputURL: outputURL, attach: attach)
        } catch {
            let reason = "could not run the check: \(error)"
            outcome.error = reason
            // The reason goes where the output would have been. If that fails too, the event still has it.
            try? FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data("\(reason)\n".utf8).write(to: outputURL)
        }

        var code: Int32?
        var signal: Int32?
        switch outcome.exit?.termination {
        case .exited(let c)?: code = c
        case .signaled(let s)?: signal = s
        case .lost?, nil: break
        }
        let result = Self.finalResult(Self.classify(outcome.exit), error: outcome.error)
        let report = CheckReport(
            turn: turn, command: command, result: result, exitCode: code, signal: signal,
            durationMs: outcome.exit?.durationMs ?? Int(Date().timeIntervalSince(started) * 1000),
            outputRef: Project.checkOutputRef(turn: turn), outputTruncated: outcome.truncated)

        var data: [String: JSONValue] = [
            "command": .string(command),
            "result": .string(report.result.rawValue),
            "exit_code": code.map { .int(Int($0)) } ?? .null,
            "signal": signal.map { .int(Int($0)) } ?? .null,
            "duration_ms": .int(report.durationMs),
            "output_ref": .string(report.outputRef),
            "output_truncated": .bool(report.outputTruncated),
        ]
        if let exit = outcome.exit {
            if exit.escalatedToKill { data["escalated_to_kill"] = true }
            if exit.sweptProcesses > 0 { data["swept_processes"] = .int(exit.sweptProcesses) }
            if exit.termination == .lost { data["lost"] = true }
        }
        if let error = outcome.error { data["error"] = .string(error) }
        if !outcome.tests.isEmpty {
            data["tests_passed"] = .array(outcome.tests.passed.map { .string($0) })
            data["tests_failed"] = .array(outcome.tests.failed.map { .string($0) })
            if outcome.tests.truncated { data["tests_truncated"] = true }
        }
        try await log.append(.checkRan, turn: turn, data: .object(data))
        return report
    }

    // MARK: Classification (pure, tested directly)

    /// A command that exited 0 but whose output could not be kept has no evidence behind it: not a pass.
    static func finalResult(_ classified: CheckResult, error: String?) -> CheckResult {
        classified == .passed && error != nil ? .failed : classified
    }

    static func classify(_ exit: ProcessExit?) -> CheckResult {
        guard let exit else { return .failed }
        switch exit.cause {
        case .stopped: return .stopped
        case .timedOut: return .timedOut
        case .natural: return exit.termination == .exited(0) ? .passed : .failed
        }
    }

    // MARK: The command

    /// The check command as a spawn request, or nil when its executable cannot be found.
    func request() -> SpawnRequest? {
        // `Config` has already refused quotes, operators and substitutions, so the words are just words.
        let words = command.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let name = words.first,
            let executable = Self.resolve(name, worktree: worktree, searchPath: environment["PATH"])
        else { return nil }
        var request = SpawnRequest(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", Self.mergeStreams, "sh", executable.path] + words.dropFirst(),
            environment: environment, workingDirectory: worktree, timeout: timeout)
        request.killGrace = killGrace
        request.maxLineBytes = Self.maxOutputBytes
        // The runner drops whole lines at its limit. Twice ours, so the file is always cut here, at the byte.
        request.maxOutputBytes = 2 * Self.maxOutputBytes + 2
        return request
    }

    /// A path is taken from the worktree (the project's own script). A bare name is looked up on PATH,
    /// absolute entries only: `.` or an empty entry would let a file in the worktree stand in for it.
    static func resolve(_ name: String, worktree: URL, searchPath: String?) -> URL? {
        if name.contains("/") {
            let path = name.hasPrefix("/") ? name : worktree.appendingPathComponent(name).path
            return ExecutableResolver.resolve(path, searchPath: nil)
        }
        let absolute = (searchPath ?? "").split(separator: ":").filter { $0.hasPrefix("/") }
        return ExecutableResolver.resolve(name, searchPath: absolute.joined(separator: ":"))
    }

    // MARK: Running

    struct Outcome {
        var exit: ProcessExit?
        var truncated = false
        var error: String?
        var tests = CheckTests()
    }

    func execute(outputURL: URL, attach: @Sendable (ProcessRun) async -> Void) async throws -> Outcome {
        guard let request = request() else {
            throw CheckError.notFound(command.split(separator: " ").first.map(String.init) ?? command)
        }
        var sink = try OutputSink(url: outputURL, limit: Self.maxOutputBytes)
        let process: ProcessRun
        do { process = try ProcessRunner.start(request) } catch {
            sink.finish()
            throw error
        }
        await attach(process)

        // The stream is read to its `exited` event even past the limit: that is what keeps the pipe empty.
        var outcome = Outcome()
        var parser = TestOutputParser()
        for await event in process.events {
            switch event {
            case .started: break
            case .line(let line):
                sink.write(line)
                parser.feed(line)
            case .oversizedLine(let preview, let total):
                // A single line over the limit: the runner kept only its start, so say how much was cut.
                sink.write("\(preview)… [line of \(total) bytes, cut after its first \(preview.count) characters]")
                sink.truncated = true
            case .exited(let exit):
                outcome.exit = exit
                if exit.outputTruncated { sink.truncated = true }
            }
        }
        sink.finish()
        outcome.tests = parser.result
        outcome.truncated = sink.truncated
        if sink.failed { outcome.error = "the output file could not be written in full" }
        return outcome
    }
}

/// The check's log file: lines in, at most `limit` bytes kept, then a marker line.
private struct OutputSink {
    private let handle: FileHandle
    private let limit: Int
    private var kept = 0
    private var endsWithNewline = true
    var truncated = false
    private(set) var failed = false

    init(url: URL, limit: Int) throws {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            throw CheckError.outputFile(error.localizedDescription)
        }
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw CheckError.outputFile(String(cString: strerror(errno))) }
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        self.limit = limit
    }

    mutating func write(_ line: String) {
        guard !truncated else { return }
        var bytes = Data(line.utf8)
        bytes.append(0x0A)
        if bytes.count > limit - kept {
            bytes = bytes.prefix(limit - kept)
            truncated = true
        }
        put(bytes)
        kept += bytes.count
        if let last = bytes.last { endsWithNewline = last == 0x0A }
    }

    mutating func finish() {
        if truncated {
            put(Data("\(endsWithNewline ? "" : "\n")[output truncated at \(limit) bytes]\n".utf8))
        }
        try? handle.close()
    }

    private mutating func put(_ bytes: Data) {
        do { try handle.write(contentsOf: bytes) } catch { failed = true }
    }
}
