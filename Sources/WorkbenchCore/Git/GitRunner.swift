import Foundation

public struct GitResult: Sendable, Equatable {
    public var status: Int32
    public var stdout: String
    public var stderr: String

    public var succeeded: Bool { status == 0 }
}

public enum GitError: Error, Equatable, Sendable {
    case gitNotFound
    case launchFailed(String)
    case timedOut(arguments: [String], seconds: Double)
}

/// Runs short, bounded commands (git) to completion. Not for `claude`: that streams and has its own
/// runner. Follows the process-layer rules in `docs/plan/P1-runner.md`:
///
/// - no `waitUntilExit`, no blocking pipe reads: output goes to temp files and the termination handler
///   resumes the caller exactly once,
/// - stdin is `/dev/null`, so nothing can wait for input,
/// - there is always a timeout, SIGTERM then SIGKILL,
/// - output is capped.
public struct GitRunner: Sendable {
    public static let outputLimit = 4 << 20

    public let executable: URL
    public let environment: [String: String]
    public let timeout: TimeInterval

    public init(executable: URL, environment: [String: String], timeout: TimeInterval = 60) {
        self.executable = executable
        self.environment = environment
        self.timeout = timeout
    }

    /// Finds `git` on PATH and builds a minimal, prompt-free environment.
    /// `extraEnvironment` is for tests (for example to ignore the user's global git config).
    public static func discover(
        from parent: [String: String] = ProcessInfo.processInfo.environment,
        extraEnvironment: [String: String] = [:],
        timeout: TimeInterval = 60
    ) throws -> GitRunner {
        guard let git = ExecutableResolver.resolve("git", searchPath: parent["PATH"])
            ?? ExecutableResolver.resolve("/usr/bin/git", searchPath: nil)
        else { throw GitError.gitNotFound }

        let keep = ["PATH", "HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "SHELL"]
        var env = parent.filter { keep.contains($0.key) || $0.key.hasPrefix("LC_") }
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["GIT_PAGER"] = "cat"
        env["LC_ALL"] = "C"
        for (key, value) in extraEnvironment { env[key] = value }
        return GitRunner(executable: git, environment: env, timeout: timeout)
    }

    public func run(_ arguments: [String], in directory: URL) async throws -> GitResult {
        let outFile = Self.scratchFile()
        let errFile = Self.scratchFile()
        defer {
            try? FileManager.default.removeItem(at: outFile)
            try? FileManager.default.removeItem(at: errFile)
        }
        guard FileManager.default.createFile(atPath: outFile.path, contents: nil),
            FileManager.default.createFile(atPath: errFile.path, contents: nil),
            let outHandle = try? FileHandle(forWritingTo: outFile),
            let errHandle = try? FileHandle(forWritingTo: errFile)
        else { throw GitError.launchFailed("cannot create scratch files") }
        defer {
            try? outHandle.close()
            try? errHandle.close()
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outHandle
        process.standardError = errHandle

        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            let run = Execution(process: process, continuation: continuation)
            process.terminationHandler = { finished in
                run.finish(status: finished.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                run.fail(GitError.launchFailed("\(executable.path): \(error.localizedDescription)"))
                return
            }
            run.armTimeout(seconds: timeout)
        }
        if status == Execution.timedOutStatus {
            throw GitError.timedOut(arguments: arguments, seconds: timeout)
        }

        return GitResult(
            status: status,
            stdout: Self.read(outFile),
            stderr: Self.read(errFile))
    }

    private static func scratchFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("wb-git-\(UUID().uuidString)")
    }

    private static func read(_ url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: outputLimit)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

/// One running command: guarantees the continuation is resumed exactly once, whichever of exit, launch
/// failure or timeout happens first.
private final class Execution: @unchecked Sendable {
    static let timedOutStatus: Int32 = .min

    private let lock = NSLock()
    private let process: Process
    private var continuation: CheckedContinuation<Int32, Error>?
    private var timedOut = false

    init(process: Process, continuation: CheckedContinuation<Int32, Error>) {
        self.process = process
        self.continuation = continuation
    }

    func finish(status: Int32) {
        lock.lock()
        let cont = continuation
        continuation = nil
        let wasTimedOut = timedOut
        lock.unlock()
        cont?.resume(returning: wasTimedOut ? Self.timedOutStatus : status)
    }

    func fail(_ error: Error) {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(throwing: error)
    }

    func armTimeout(seconds: TimeInterval) {
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [self] in
            lock.lock()
            let live = continuation != nil && process.isRunning
            if live { timedOut = true }
            let pid = process.processIdentifier
            lock.unlock()
            guard live else { return }
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [self] in
                lock.lock()
                let stillRunning = continuation != nil && process.isRunning
                lock.unlock()
                if stillRunning { kill(pid, SIGKILL) }
            }
        }
    }
}
