import Foundation

public struct GitResult: Sendable, Equatable {
    public var status: Int32
    public var stdout: String
    public var stderr: String

    public var succeeded: Bool { status == 0 }
}

public enum GitError: Error, Equatable, Sendable {
    case gitNotFound
    case toolNotFound(String)
    case launchFailed(String)
    case timedOut(arguments: [String], seconds: Double)
}

/// Runs short, bounded commands (git) to completion. Not for `claude`: that streams and has its own
/// runner. Follows the process-layer rules in `docs/plan/P1-runner.md`:
///
/// - started through `Spawner`, so the child inherits nothing but stdin, stdout and stderr (rule 8),
/// - no blocking wait, no blocking pipe reads: output goes to temp files and a kqueue exit watcher resumes
///   the caller exactly once,
/// - stdin is `/dev/null`, so nothing can wait for input,
/// - its own process group, killed as a whole on timeout and after exit, so no stray hook or helper stays,
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

    /// Finds `git` (or another short command such as `gh`) on PATH and builds a minimal, prompt-free
    /// environment. `gh` also keeps what it needs to use the person's own login. `extraEnvironment` is for
    /// tests (for example to ignore the user's global git config).
    public static func discover(
        tool: String = "git",
        from parent: [String: String] = ProcessInfo.processInfo.environment,
        extraEnvironment: [String: String] = [:],
        timeout: TimeInterval = 60
    ) throws -> GitRunner {
        guard let git = ExecutableResolver.resolve(tool, searchPath: parent["PATH"])
            ?? (tool == "git" ? ExecutableResolver.resolve("/usr/bin/git", searchPath: nil) : nil)
        else { throw tool == "git" ? GitError.gitNotFound : GitError.toolNotFound(tool) }

        // `SSH_AUTH_SOCK` is the person's own agent: a push or `ls-remote` over ssh needs it, and this
        // environment is Workbench's, never the model's.
        let keep = ["PATH", "HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "SHELL", "SSH_AUTH_SOCK"]
        let keepPrefixes: [String]
        switch tool {
        case "gh": keepPrefixes = ["LC_", "GH_", "GITHUB_", "XDG_CONFIG"]
        // The uploader uses the person's own gh login and store keys; this runs for `ship`, never for the model.
        case "pr-shots": keepPrefixes = ["LC_", "GH_", "GITHUB_", "XDG_CONFIG", "PR_SHOTS_", "AWS_", "CLOUDFLARE_"]
        default: keepPrefixes = ["LC_"]
        }
        var env = parent.filter { entry in
            keep.contains(entry.key) || keepPrefixes.contains { entry.key.hasPrefix($0) }
        }
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
        let outFD = open(outFile.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
        let errFD = open(errFile.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
        guard outFD >= 0, errFD >= 0 else {
            if outFD >= 0 { close(outFD) }
            if errFD >= 0 { close(errFD) }
            throw GitError.launchFailed("cannot create scratch files")
        }

        let pid: pid_t
        do {
            pid = try Spawner.spawn(
                executable: executable.path, arguments: arguments, environment: environment,
                workingDirectory: directory.path, stdout: outFD, stderr: errFD)
        } catch {
            close(outFD)
            close(errFD)
            throw GitError.launchFailed("\(error)")
        }
        close(outFD)
        close(errFD)

        let outcome = await ShortCommand(pid: pid, timeout: timeout).wait()
        if outcome.timedOut { throw GitError.timedOut(arguments: arguments, seconds: timeout) }

        let status: Int32
        switch outcome.termination {
        case .exited(let code): status = code
        case .signaled(let signal): status = 128 + signal
        case .lost: status = -1
        }
        return GitResult(status: status, stdout: Self.read(outFile), stderr: Self.read(errFile))
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

/// One short-lived child: resumes its waiter exactly once, whichever of exit or timeout comes first.
private final class ShortCommand: @unchecked Sendable {
    struct Outcome: Sendable {
        var termination: Termination
        var timedOut: Bool
    }

    private let pid: pid_t
    private let timeout: TimeInterval
    private let queue = DispatchQueue(label: "workbench.shortcommand")
    private var continuation: CheckedContinuation<Outcome, Never>?
    private var watcher: ChildExitWatcher?
    private var timeoutTimer: DispatchSourceTimer?
    private var killTimer: DispatchSourceTimer?
    private var timedOut = false

    init(pid: pid_t, timeout: TimeInterval) {
        self.pid = pid
        self.timeout = timeout
    }

    func wait() async -> Outcome {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                self.continuation = continuation
                watcher = ChildExitWatcher(pid: pid, queue: queue) { [self] in exited() }
                timeoutTimer = timer(after: timeout) { [self] in
                    timedOut = true
                    killpg(pid, SIGTERM)
                    kill(pid, SIGTERM)
                    killTimer = timer(after: 2) { [self] in
                        killpg(pid, SIGKILL)
                        kill(pid, SIGKILL)
                    }
                }
            }
        }
    }

    private func exited() {
        timeoutTimer?.cancel(); timeoutTimer = nil
        killTimer?.cancel(); killTimer = nil
        // Still a zombie, so the group id is ours: take anything the command left behind with it.
        killpg(pid, SIGKILL)
        let termination = watcher?.reap() ?? .lost
        watcher = nil
        let cont = continuation
        continuation = nil
        cont?.resume(returning: Outcome(termination: termination, timedOut: timedOut))
    }

    private func timer(after delay: TimeInterval, _ handler: @escaping @Sendable () -> Void) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler(handler: handler)
        timer.resume()
        return timer
    }
}
