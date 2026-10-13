import Foundation

/// What one run of the project's check command came to.
public struct CheckOutcome: Sendable, Equatable {
    public enum Result: String, Sendable, Equatable {
        case passed
        case failed
        case timedOut = "timed_out"
        case stopped
        /// The runner died while the check was running. Only ever written by recovery.
        case interrupted
    }

    public var command: String
    public var result: Result
    public var exitCode: Int32?
    public var signal: Int32?
    public var durationMs: Int
    /// Path of the captured output relative to the thread directory, for example `checks/turn-2.log`.
    public var outputRef: String
    public var outputTruncated: Bool
    public var error: String?

    public var passed: Bool { result == .passed }

    var eventData: JSONValue {
        var data: [String: JSONValue] = [
            "command": .string(command),
            "result": .string(result.rawValue),
            "exit_code": exitCode.map { .int(Int($0)) } ?? .null,
            "duration_ms": .int(durationMs),
            "output_ref": .string(outputRef),
            "output_truncated": .bool(outputTruncated),
        ]
        if let signal { data["signal"] = .int(Int(signal)) }
        if let error { data["error"] = .string(error) }
        return .object(data)
    }
}

/// Runs the project's check command in a worktree, itself, so a pass is evidence and not Claude's say-so.
/// Built on `ProcessRunner`, so it has the guarantees of a turn: a timeout, SIGTERM then SIGKILL, the whole
/// process tree swept at the end, bounded output, and exactly one result however the command ends.
public enum CheckRunner {
    public static let maxOutputBytes = 1 << 20

    /// Runs `command` (one plain command, already validated by `Config`) with the worktree as its working
    /// directory. Stdout and stderr go to `logURL` in the order written. Cancelling the calling task stops it.
    ///
    /// The command text is split on whitespace and handed to `exec` as separate arguments; no shell ever
    /// parses it. The shell only exists to put stderr on stdout.
    public static func run(
        command: String,
        worktree: URL,
        environment: [String: String],
        timeout: TimeInterval,
        killGrace: TimeInterval = 5,
        maxOutputBytes: Int = CheckRunner.maxOutputBytes,
        logURL: URL,
        outputRef: String
    ) async -> CheckOutcome {
        func outcome(
            _ result: CheckOutcome.Result, exit: Int32? = nil, signal: Int32? = nil, durationMs: Int = 0,
            truncated: Bool = false, error: String? = nil
        ) -> CheckOutcome {
            CheckOutcome(
                command: command, result: result, exitCode: exit, signal: signal, durationMs: durationMs,
                outputRef: outputRef, outputTruncated: truncated, error: error)
        }
        let words = command.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard !words.isEmpty else { return outcome(.failed, error: "the check command is empty") }

        let fm = FileManager.default
        do {
            try fm.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: logURL.path, contents: nil)
        } catch {
            return outcome(.failed, error: "cannot create \(logURL.path): \(error)")
        }
        guard let sink = try? FileHandle(forWritingTo: logURL) else {
            return outcome(.failed, error: "cannot open \(logURL.path)")
        }
        defer { try? sink.close() }

        var spawn = SpawnRequest(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "exec \"$@\" 2>&1", "check"] + words,
            environment: environment, workingDirectory: worktree, timeout: timeout)
        spawn.killGrace = killGrace
        spawn.maxOutputBytes = maxOutputBytes

        let process: ProcessRun
        do { process = try ProcessRunner.start(spawn) } catch {
            return outcome(.failed, error: "could not start the check: \(error)")
        }

        // The stream is read from a task of its own: iterating an `AsyncStream` from a cancelled task ends
        // early and would lose the `exited` record, which is what says the check was stopped.
        let reader = Task.detached { () -> ProcessExit? in
            var exit: ProcessExit?
            for await event in process.events {
                switch event {
                case .started:
                    break
                case .line(let line):
                    try? sink.write(contentsOf: Data((line + "\n").utf8))
                case .oversizedLine(let preview, let total):
                    try? sink.write(contentsOf: Data("\(preview)… [line cut: \(total) bytes]\n".utf8))
                case .exited(let e):
                    exit = e
                }
            }
            return exit
        }
        return await withTaskCancellationHandler {
            guard let exit = await reader.value else {
                return outcome(.failed, error: "the check ended without an exit record")
            }
            if exit.outputTruncated {
                var note = "[output truncated at \(maxOutputBytes) bytes]\n"
                if let last = exit.lastLineAfterLimit { note += last + "\n" }
                try? sink.write(contentsOf: Data(note.utf8))
            }
            var code: Int32?
            var signal: Int32?
            switch exit.termination {
            case .exited(let c): code = c
            case .signaled(let s): signal = s
            case .lost: break
            }
            let result: CheckOutcome.Result
            switch exit.cause {
            case .timedOut: result = .timedOut
            case .stopped: result = .stopped
            case .natural: result = code == 0 ? .passed : .failed
            }
            return outcome(
                result, exit: code, signal: signal, durationMs: exit.durationMs, truncated: exit.outputTruncated)
        } onCancel: {
            process.stop()
        }
    }
}

extension CheckOutcome {
    /// The record recovery writes for a check whose runner died.
    static func recovered(command: String?) -> CheckOutcome {
        CheckOutcome(
            command: command ?? "", result: .interrupted, exitCode: nil, signal: nil, durationMs: 0,
            outputRef: "", outputTruncated: false, error: nil)
    }
}
