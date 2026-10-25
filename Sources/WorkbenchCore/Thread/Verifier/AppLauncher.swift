import Foundation

#if canImport(Network)
import Network
#endif

/// Starts the project's `[run]` command for one verifier turn and stops it when the turn ends
/// (docs/plan/P16-run.md). It is the check's machinery (one `ProcessRunner` child, its streams merged, its whole
/// process tree swept on every ending) with a ready check in front: the verifier is only started once the app is up.
struct AppLauncher {
    /// What the app is told besides the allowlisted environment.
    static let portVariables = ["WORKBENCH_PORT", "PORT"]

    var run: RunConfig
    var worktree: URL
    var environment: [String: String]
    /// Past this the app is ended whatever the turn is doing: it must never outlive the verifier by much.
    var lifetime: TimeInterval
    var killGrace: TimeInterval

    /// A running app, and what to say about it.
    final class Running: @unchecked Sendable {
        let pid: Int32
        let port: Int
        /// The URL with `{port}` filled in, for a `ready_url` check.
        let url: String?
        let readyMs: Int
        fileprivate let process: ProcessRun
        fileprivate let state: AppState
        fileprivate let reader: Task<Void, Never>

        fileprivate init(
            pid: Int32, port: Int, url: String?, readyMs: Int, process: ProcessRun, state: AppState, reader: Task<Void, Never>
        ) {
            self.pid = pid
            self.port = port
            self.url = url
            self.readyMs = readyMs
            self.process = process
            self.state = state
            self.reader = reader
        }

        /// Ends the app and everything under it, and says how it ended. Safe to call more than once.
        func stop() async -> AppEnd {
            let exitedBefore = await state.exit
            if exitedBefore == nil { process.stop() }
            await reader.value
            let exit = await state.exit
            return AppEnd(ready: true, exit: exit, exitedEarly: exitedBefore != nil, tail: await state.tail)
        }
    }

    /// How the app ended, for `run.ended`.
    struct AppEnd: Equatable {
        var ready: Bool
        var exit: ProcessExit?
        /// It ended on its own before it was stopped.
        var exitedEarly: Bool
        var tail: [String]
    }

    enum Failure: Error, Equatable {
        case notFound(String)
        case cannotStart
        case exited(AppEnd)
        case notReady(seconds: Int, tail: [String])

        var description: String {
            switch self {
            case .notFound(let name): "the [run] command '\(name)' was not found"
            case .cannotStart: "the [run] command could not be started"
            case .exited(let end):
                end.exit?.cause == .stopped
                    ? "the verifier was stopped"
                    : "the app ended before it was ready" + (end.exit.map { " (\(Self.how($0)))" } ?? "")
            case .notReady(let seconds, _): "the app was not ready within \(seconds)s"
            }
        }

        /// Process output worth showing next to the reason.
        var tail: [String] {
            switch self {
            case .exited(let end): end.tail
            case .notReady(_, let tail): tail
            default: []
            }
        }

        static func how(_ exit: ProcessExit) -> String {
            switch exit.termination {
            case .exited(let code): "exit \(code)"
            case .signaled(let signal): "signal \(signal)"
            case .lost: "lost"
            }
        }
    }

    /// Starts the command and waits until it is ready, has ended, or `ready_timeout_s` is up. On any failure the app
    /// is already stopped.
    func start(
        port: Int, threadID: String, goalPath: String, attach: @Sendable (ProcessRun) -> Void = { _ in }
    ) async -> Result<Running, Failure> {
        let words = run.command.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let name = words.first,
            let executable = CheckRunner.resolve(name, worktree: worktree, searchPath: environment["PATH"])
        else { return .failure(.notFound(run.command.split(separator: " ").first.map(String.init) ?? run.command)) }

        var env = environment
        for key in Self.portVariables { env[key] = String(port) }
        env["WORKBENCH_THREAD"] = threadID
        env["WORKBENCH_GOAL"] = goalPath
        var request = SpawnRequest(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", CheckRunner.mergeStreams, "sh", executable.path] + words.dropFirst(),
            environment: env, workingDirectory: worktree, timeout: lifetime)
        request.killGrace = killGrace
        request.maxLineBytes = 8 << 10

        let began = Date()
        let process: ProcessRun
        do { process = try ProcessRunner.start(request) } catch { return .failure(.cannotStart) }
        // `stop` during the wait reaches the app, which then ends the turn as a stop.
        attach(process)
        let matcher: NSRegularExpression? = {
            if case .line(let pattern) = run.ready { return try? NSRegularExpression(pattern: pattern) }
            return nil
        }()
        let state = AppState()
        // The stream is read to its `exited` event, which is what keeps the pipe empty and ends the tree.
        let reader = Task {
            for await event in process.events {
                switch event {
                case .started: break
                case .line(let line):
                    await state.add(line: line, matches: matcher.map { Self.matches($0, line) } ?? false)
                case .oversizedLine(let preview, _):
                    await state.add(line: preview, matches: false)
                case .exited(let exit):
                    await state.finish(exit)
                }
            }
        }

        let url: String? = {
            if case .url(let pattern) = run.ready { return pattern.replacingOccurrences(of: "{port}", with: String(port)) }
            return nil
        }()
        let deadline = began.addingTimeInterval(TimeInterval(run.readyTimeoutS))
        while true {
            if let exit = await state.exit {
                await reader.value
                return .failure(.exited(AppEnd(ready: false, exit: exit, exitedEarly: true, tail: await state.tail)))
            }
            let up: Bool
            if let url { up = await Self.answers(url) } else { up = await state.matched }
            if up {
                let ms = Int(Date().timeIntervalSince(began) * 1000)
                return .success(
                    Running(
                        pid: process.pid, port: port, url: url, readyMs: ms, process: process, state: state,
                        reader: reader))
            }
            if Date() >= deadline {
                process.stop()
                await reader.value
                return .failure(.notReady(seconds: run.readyTimeoutS, tail: await state.tail))
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    // MARK: Checks

    static func matches(_ regex: NSRegularExpression, _ line: String) -> Bool {
        regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    #if canImport(Network)
    /// Any HTTP answer, whatever its status, means something is listening and serving. It is the status line that
    /// counts, read from a plain TCP connection: nothing follows a redirect (the check stays on this machine, and a 3xx
    /// is an answer already), the body is never read (a server that streams one cannot hold the check or grow our
    /// memory), and the whole attempt ends within `attempt` seconds.
    static func answers(_ url: String, attempt: TimeInterval = 1.5) async -> Bool {
        guard let url = URL(string: url), let host = url.host, let number = url.port,
            let port = NWEndpoint.Port(rawValue: UInt16(clamping: number))
        else { return false }
        let target = (url.path.isEmpty ? "/" : url.path) + (url.query.map { "?" + $0 } ?? "")
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        let queue = DispatchQueue(label: "workbench.ready-check")
        return await withCheckedContinuation { continuation in
            let once = Once(continuation)
            let request = Data("GET \(target) HTTP/1.0\r\nHost: \(host)\r\nConnection: close\r\n\r\n".utf8)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: request, completion: .contentProcessed { _ in })
                    connection.receive(minimumIncompleteLength: 5, maximumLength: 16) { data, _, _, _ in
                        once.resume(data.map { String(decoding: $0, as: UTF8.self).hasPrefix("HTTP/") } ?? false)
                        connection.cancel()
                    }
                case .failed, .cancelled:
                    once.resume(false)
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + attempt) {
                once.resume(false)
                connection.cancel()
            }
        }
    }

    /// Resumes a continuation once, whichever of the answer, the failure and the deadline comes first.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?
        init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }
        func resume(_ value: Bool) {
            lock.lock()
            let taken = continuation
            continuation = nil
            lock.unlock()
            taken?.resume(returning: value)
        }
    }
    #endif

    /// A port nothing listens on: the kernel picks one for a socket that is closed again at once.
    static func freePort() -> Int? {
        let fd = socket(AF_INET, streamSocketType, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: UInt32(0x7f00_0001).bigEndian)
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
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

/// What the reader task has seen of the app, shared with the code that waits on it.
private actor AppState {
    private static let tailLines = 20
    private(set) var exit: ProcessExit?
    private(set) var matched = false
    private var lines: [String] = []

    var tail: [String] { lines.map { ThreadState.safeLine($0, limit: 200) } }

    func add(line: String, matches: Bool) {
        if matches { matched = true }
        lines.append(line)
        if lines.count > Self.tailLines { lines.removeFirst(lines.count - Self.tailLines) }
    }

    func finish(_ exit: ProcessExit) { self.exit = exit }
}
