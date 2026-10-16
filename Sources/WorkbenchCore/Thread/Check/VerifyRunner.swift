import CryptoKit
import Foundation

/// One file the verify step left in the proof directory, as `proof.added` recorded it.
public struct ProofFile: Sendable, Equatable {
    /// Relative to the proof directory.
    public var name: String
    /// Relative to the thread directory.
    public var path: String
    public var sha256: String
    public var bytes: Int
}

public struct VerifyReport: Sendable, Equatable {
    public var turn: Int
    public var command: String
    public var result: CheckResult
    public var exitCode: Int32?
    public var signal: Int32?
    public var durationMs: Int
    /// Relative to the thread directory.
    public var outputRef: String
    public var outputTruncated: Bool
    public var proof: [ProofFile]
}

/// Runs the project's `verify_command` after a turn's check and records `verify.started`, one `proof.added`
/// per file it left behind, and `verify.ended`.
///
/// It is the check's machinery (one `ProcessRunner` child, bounded in time and output, merged streams,
/// process tree swept, minimal environment) plus a small contract: the command gets an empty proof
/// directory and a free port in its environment and writes its evidence there. Whatever it exits with, the
/// files are recorded as found; a pass is never inferred from them.
struct VerifyRunner {
    /// Most files recorded per run. Past it the rest are counted, not listed.
    static let maxFiles = 200

    var command: String
    var worktree: URL
    var environment: [String: String]
    var timeout: TimeInterval
    var killGrace: TimeInterval
    var threadID: String
    var goalPath: String

    func run(
        turn: Int, proofDirectory: URL, threadDirectory: URL, outputURL: URL, log: EventLogWriter,
        attach: @Sendable (ProcessRun) async -> Void
    ) async throws -> VerifyReport {
        let proofRef = Project.proofRef(turn: turn)
        let port = Self.freePort()
        try Self.resetDirectory(proofDirectory)
        try await log.append(
            .verifyStarted, turn: turn,
            data: [
                "command": .string(command), "proof_ref": .string(proofRef),
                "port": port.map { .int($0) } ?? .null,
            ])
        let started = Date()

        var env = environment
        env["WORKBENCH_PROOF_DIR"] = proofDirectory.path
        env["WORKBENCH_THREAD"] = threadID
        env["WORKBENCH_GOAL"] = goalPath
        if let port { env["WORKBENCH_PORT"] = String(port) }
        let runner = CheckRunner(
            command: command, worktree: worktree, environment: env, timeout: timeout, killGrace: killGrace)

        var outcome = CheckRunner.Outcome()
        do {
            outcome = try await runner.execute(outputURL: outputURL, attach: attach)
        } catch {
            let reason = "could not run the verify step: \(error)"
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

        let (files, omitted) = Self.collect(proofDirectory: proofDirectory, threadDirectory: threadDirectory)
        for file in files {
            try await log.append(
                .proofAdded, turn: turn,
                data: [
                    "name": .string(file.name), "path": .string(file.path), "sha256": .string(file.sha256),
                    "bytes": .int(file.bytes),
                ])
        }

        let report = VerifyReport(
            turn: turn, command: command, result: result, exitCode: code, signal: signal,
            durationMs: outcome.exit?.durationMs ?? Int(Date().timeIntervalSince(started) * 1000),
            outputRef: Project.verifyOutputRef(turn: turn), outputTruncated: outcome.truncated, proof: files)

        var data: [String: JSONValue] = [
            "command": .string(command), "result": .string(result.rawValue),
            "exit_code": code.map { .int(Int($0)) } ?? .null, "signal": signal.map { .int(Int($0)) } ?? .null,
            "duration_ms": .int(report.durationMs), "output_ref": .string(report.outputRef),
            "output_truncated": .bool(report.outputTruncated), "proof_files": .int(files.count),
        ]
        if omitted > 0 { data["proof_omitted"] = .int(omitted) }
        if let exit = outcome.exit {
            if exit.escalatedToKill { data["escalated_to_kill"] = true }
            if exit.sweptProcesses > 0 { data["swept_processes"] = .int(exit.sweptProcesses) }
            if exit.termination == .lost { data["lost"] = true }
        }
        if let error = outcome.error { data["error"] = .string(error) }
        try await log.append(.verifyEnded, turn: turn, data: .object(data))
        return report
    }

    // MARK: Proof directory

    /// Removes whatever an earlier run left and creates the directory empty.
    static func resetDirectory(_ url: URL) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: url)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// The regular files under `proofDirectory`, sorted by name. Symlinks and anything else are left out, so
    /// the command cannot point the record at a file elsewhere on disk.
    static func collect(proofDirectory: URL, threadDirectory: URL) -> (files: [ProofFile], omitted: Int) {
        let fm = FileManager.default
        let root = proofDirectory.resolvingSymlinksInPath().path
        guard
            let walker = fm.enumerator(
                at: proofDirectory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
                options: [])
        else { return ([], 0) }
        var paths: [URL] = []
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                values.isSymbolicLink != true, values.isRegularFile == true
            else { continue }
            paths.append(url)
        }
        paths.sort { $0.path < $1.path }
        var files: [ProofFile] = []
        for url in paths.prefix(maxFiles) {
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { continue }
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let full = url.resolvingSymlinksInPath().path
            let name = full.hasPrefix(root + "/") ? String(full.dropFirst(root.count + 1)) : url.lastPathComponent
            files.append(
                ProofFile(
                    name: name,
                    path: relative(url, to: threadDirectory),
                    sha256: digest, bytes: data.count))
        }
        return (files, max(0, paths.count - maxFiles))
    }

    private static func relative(_ url: URL, to base: URL) -> String {
        let full = url.resolvingSymlinksInPath().path
        let root = base.resolvingSymlinksInPath().path
        return full.hasPrefix(root + "/") ? String(full.dropFirst(root.count + 1)) : url.lastPathComponent
    }

    // MARK: Port

    /// A TCP port that was free a moment ago, so two worktrees never ask for the same one. Not reserved:
    /// the command binds it, and a race with another process is possible but rare.
    static func freePort() -> Int? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: UInt32(INADDR_LOOPBACK).bigEndian)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { return nil }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else { return nil }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}
