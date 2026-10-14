import Foundation

public struct SetupReport: Sendable, Equatable {
    public var command: String
    public var result: CheckResult
    public var exitCode: Int32?
    public var signal: Int32?
    public var durationMs: Int
    /// Relative to the thread directory.
    public var outputRef: String
    public var outputTruncated: Bool

    /// Why it did not pass, in words, for the error that stops the start.
    var how: String {
        switch result {
        case .passed: "passed"
        case .failed: exitCode.map { "failed (exit \($0))" } ?? signal.map { "failed (signal \($0))" } ?? "failed"
        case .timedOut: "timed out"
        case .stopped: "was stopped"
        case .interrupted: "was interrupted"
        }
    }
}

/// Runs the project's `setup_command` once in a new worktree, before its first turn, and records
/// `setup.ran`. It is the check's machinery (one `ProcessRunner` child, bounded in time and output, merged
/// streams, process tree swept) with its own event and file.
struct SetupRunner {
    /// An install step is slower than most checks but must still end.
    static let defaultTimeout: TimeInterval = 15 * 60

    var command: String
    var worktree: URL
    var environment: [String: String]
    var timeout: TimeInterval
    var killGrace: TimeInterval

    func run(
        outputURL: URL, log: EventLogWriter, attach: @Sendable (ProcessRun) async -> Void
    ) async throws -> SetupReport {
        let started = Date()
        let runner = CheckRunner(
            command: command, worktree: worktree, environment: environment, timeout: timeout, killGrace: killGrace)
        var outcome = CheckRunner.Outcome()
        do {
            outcome = try await runner.execute(outputURL: outputURL, attach: attach)
        } catch {
            let reason = "could not run the setup: \(error)"
            outcome.error = reason
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
        let result = CheckRunner.finalResult(CheckRunner.classify(outcome.exit), error: outcome.error)
        let report = SetupReport(
            command: command, result: result, exitCode: code, signal: signal,
            durationMs: outcome.exit?.durationMs ?? Int(Date().timeIntervalSince(started) * 1000),
            outputRef: Project.setupOutputRef, outputTruncated: outcome.truncated)

        var data: [String: JSONValue] = [
            "command": .string(command), "result": .string(result.rawValue),
            "exit_code": code.map { .int(Int($0)) } ?? .null, "signal": signal.map { .int(Int($0)) } ?? .null,
            "duration_ms": .int(report.durationMs), "output_ref": .string(report.outputRef),
            "output_truncated": .bool(report.outputTruncated),
        ]
        if let exit = outcome.exit {
            if exit.escalatedToKill { data["escalated_to_kill"] = true }
            if exit.sweptProcesses > 0 { data["swept_processes"] = .int(exit.sweptProcesses) }
            if exit.termination == .lost { data["lost"] = true }
        }
        if let error = outcome.error { data["error"] = .string(error) }
        try await log.append(.setupRan, turn: 0, data: .object(data))
        return report
    }

    /// The last lines of the output, one line each and safe to print: what the person needs to see why.
    static func tail(of url: URL, lines: Int = 20, bytes: Int = 4096) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > UInt64(bytes) ? size - UInt64(bytes) : 0)
        let text = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
        let kept = text.split(separator: "\n", omittingEmptySubsequences: true).suffix(lines)
        return kept.map { "  " + ThreadState.safeLine(String($0), limit: 200) }.joined(separator: "\n")
    }
}
