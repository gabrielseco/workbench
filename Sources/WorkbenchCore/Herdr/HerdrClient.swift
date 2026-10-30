import Foundation

/// Why a `herdr` call did not give an answer: its own error (a code and a sentence), or one of ours.
public struct HerdrFailure: Error, Equatable, Sendable, CustomStringConvertible {
    public var code: String?
    public var message: String
    public var description: String { message }

    public init(code: String? = nil, message: String) {
        self.code = code
        self.message = message
    }

    /// The server is not up; nothing else.
    public var serverDown: Bool { code == "server_not_running" }
}

/// One `herdr` command at a time, through core's process layer: bounded time, bounded output, its group swept on a timeout. Herdr
/// answers each command with one JSON line (`{"result": …}`) or exits 1 with `{"error": {"code", "message"}}` on stderr.
public struct HerdrClient: Sendable {
    public var executable: URL
    public var environment: [String: String]
    public var timeout: TimeInterval

    public init(executable: URL, environment: [String: String] = [:], timeout: TimeInterval = 10) {
        self.executable = executable
        self.environment = environment
        self.timeout = timeout
    }

    /// What `herdr` needs from the window's environment to find its session, and nothing else.
    public static func environment(from parent: [String: String]) -> [String: String] {
        let names: Set<String> = ["HOME", "USER", "LOGNAME", "PATH", "TMPDIR", "LANG", "SHELL"]
        return parent.filter { names.contains($0.key) || $0.key.hasPrefix("LC_") || $0.key.hasPrefix("XDG_") }
    }

    /// The `result` of one command. Throws `HerdrFailure` for an error answer, a hang, or an answer that is not JSON.
    public func call(_ arguments: [String]) async throws -> JSONValue {
        var request = SpawnRequest(
            executable: executable, arguments: arguments, environment: environment,
            workingDirectory: URL(fileURLWithPath: "/"), timeout: timeout)
        request.killGrace = 1
        request.drainGrace = 1
        request.maxOutputBytes = 256 << 10
        let run: ProcessRun
        do { run = try ProcessRunner.start(request) } catch {
            throw HerdrFailure(code: "launch_failed", message: "could not start \(executable.path): \(error)")
        }
        var lines: [String] = []
        var exit: ProcessExit?
        for await event in run.events {
            switch event {
            case .line(let line): if lines.count < 20 { lines.append(line) }
            case .exited(let ended): exit = ended
            default: break
            }
        }
        guard let exit else { throw HerdrFailure(code: "no_exit", message: "herdr ended without saying how") }
        if exit.cause == .timedOut {
            throw HerdrFailure(code: "timeout", message: "herdr did not answer within \(Int(timeout)) seconds and was stopped")
        }
        if case .exited(0) = exit.termination {
            for line in lines.reversed() {
                if let json = Self.parse(line), let result = json["result"] { return result }
            }
            throw HerdrFailure(code: "bad_answer", message: "herdr answered with something that is not JSON")
        }
        throw Self.failure(stderr: exit.stderrTail, stdout: lines)
    }

    /// The error answer in what the command wrote, else its last printable line.
    static func failure(stderr: String, stdout: [String]) -> HerdrFailure {
        let all = (stderr.split(whereSeparator: \.isNewline).map(String.init) + stdout).reversed()
        for line in all {
            if let error = parse(line)?["error"] {
                let code = error["code"]?.stringValue
                let message = error["message"]?.stringValue ?? "herdr refused it"
                return HerdrFailure(code: code, message: ThreadState.safeLine(message, limit: 200))
            }
        }
        let last = all.first { !$0.allSatisfy(\.isWhitespace) }.map { ThreadState.safeLine($0, limit: 200) }
        return HerdrFailure(code: "failed", message: last ?? "herdr failed without a message")
    }

    static func parse(_ line: String) -> JSONValue? {
        try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
    }
}

/// What opening a folder in Herdr did.
public enum HerdrOpened: Equatable, Sendable {
    /// Herdr opened it as a git worktree workspace (or already had it open).
    case worktree(workspace: String, alreadyOpen: Bool)
    /// Herdr would not open it as a worktree: the plain folder is a workspace now (or already was).
    case folder(workspace: String, alreadyOpen: Bool)
}

/// "Open in Herdr": starts the Herdr app when its server is down, then opens the thread's worktree and brings it forward.
public struct HerdrOpener: Sendable {
    public var client: HerdrClient
    /// Starts the Herdr app; the window's launcher, not a process of core's.
    public var launchApp: @Sendable () async throws -> Void
    /// How long to wait for the server after starting the app, and how often to ask.
    public var startupWait: TimeInterval = 20
    public var pollInterval: TimeInterval = 0.5

    public init(client: HerdrClient, launchApp: @escaping @Sendable () async throws -> Void) {
        self.client = client
        self.launchApp = launchApp
    }

    /// Never passes `--trust-repository`: that is for a person who has verified the repository.
    public func open(project: URL, folder: URL, label: String) async throws -> HerdrOpened {
        if await serverIsDown() {
            try await launchApp()
            try await waitForServer()
        }
        do {
            let result = try await client.call(
                ["worktree", "open", "--cwd", project.path, "--path", folder.path, "--focus"])
            return .worktree(
                workspace: result["workspace"]?["workspace_id"]?.stringValue ?? "", alreadyOpen: result["already_open"] == true)
        } catch let refusal as HerdrFailure {
            // Not a refusal of the folder: the server went away or hung, and a second command would say the same.
            if refusal.serverDown || refusal.code == "timeout" || refusal.code == "launch_failed" { throw refusal }
        }
        if let existing = try await workspace(showing: folder) {
            _ = try await client.call(["workspace", "focus", existing])
            return .folder(workspace: existing, alreadyOpen: true)
        }
        let made = try await client.call(["workspace", "create", "--cwd", folder.path, "--label", label, "--focus"])
        return .folder(workspace: made["workspace"]?["workspace_id"]?.stringValue ?? "", alreadyOpen: false)
    }

    /// Only a server that says it is not running is down; any other failure is left for the real command to report.
    func serverIsDown() async -> Bool {
        do {
            _ = try await client.call(["workspace", "list"])
            return false
        } catch let failure as HerdrFailure { return failure.serverDown } catch { return false }
    }

    func waitForServer() async throws {
        let deadline = Date().addingTimeInterval(startupWait)
        while Date() < deadline {
            if !(await serverIsDown()) { return }
            try await Task.sleep(for: .seconds(pollInterval))
        }
        throw HerdrFailure(
            code: "server_not_running",
            message: "Herdr was started but its server did not come up within \(Int(startupWait)) seconds")
    }

    /// The workspace whose pane is in `folder`, from the panes of every workspace.
    func workspace(showing folder: URL) async throws -> String? {
        let result = try await client.call(["pane", "list"])
        guard case .array(let panes)? = result["panes"] else { return nil }
        let wanted = folder.resolvingSymlinksInPath().path
        return panes.first { pane in
            guard let cwd = pane["cwd"]?.stringValue else { return false }
            return URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path == wanted
        }?["workspace_id"]?.stringValue
    }
}
