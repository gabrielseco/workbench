import Foundation

// fake-claude: a scriptable stand-in for `claude -p --output-format stream-json`, for tests.
//
// It accepts the real CLI's flags (and ignores most of them) so the runner can be pointed at it with
// `claude_path`. What it does is controlled by the FAKE_CLAUDE environment variable: a comma-separated
// list of `key` or `key=value` directives. Values cannot contain commas.
//
//   fixture=<file>        replay this JSONL instead of the built-in three-line turn (session id rewritten)
//   stream-events=<n>     built-in turn: emit n stream_event lines first
//   delay-ms=<n>          sleep between lines
//   hang-after=<n>        after n lines, sleep forever
//   crash-after=<n>       after n lines, exit 70 with no result
//   die-after=<n>         after n lines, SIGKILL itself
//   no-result             built-in turn: leave out the result line, exit 0
//   exit=<n>              exit status at the end (default 0)
//   invalid-line          put a line that is not JSON before the last line
//   flood=<bytes>         put one valid JSON line of about this size before the last line
//   partial-tail          write the last line without a trailing newline
//   ignore-term           ignore SIGTERM (default: stop the grandchild and exit 143, like the real CLI)
//   grandchild=<pidfile>  start a `sleep` in its own process group, write its pid to the file
//   ready=<file>          create this file once signal handling and the grandchild are set up, so a
//                         test can signal the process without racing its startup
//   dump=<file>           write argv, environment, cwd, open descriptors and stdin state as JSON
//   sessions=<dir>        emulate session bookkeeping: --session-id twice, or --resume of an unknown id,
//                         exits 1 with no output (the first is spike S4; the second message is a guess)

struct Directives {
    private var values: [String: String] = [:]

    init(_ raw: String?) {
        guard let raw, !raw.isEmpty else { return }
        for item in raw.split(separator: ",") {
            let parts = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            values[String(parts[0])] = parts.count > 1 ? String(parts[1]) : ""
        }
    }

    func has(_ key: String) -> Bool { values[key] != nil }
    func string(_ key: String) -> String? { values[key].flatMap { $0.isEmpty ? nil : $0 } }
    func int(_ key: String) -> Int? { values[key].flatMap { Int($0) } }
}

func argument(after flag: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func json(_ object: [String: Any]) -> String {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    return String(decoding: data, as: UTF8.self)
}

func write(_ text: String) {
    FileHandle.standardOutput.write(Data(text.utf8))
}

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

let args = Array(CommandLine.arguments.dropFirst())
let d = Directives(ProcessInfo.processInfo.environment["FAKE_CLAUDE"])

let sessionArg = argument(after: "--session-id", in: args)
let resumeArg = argument(after: "--resume", in: args)
let sessionID = sessionArg ?? resumeArg ?? UUID().uuidString.lowercased()
let prompt = args.firstIndex(of: "--").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? ""

// MARK: dump

if let path = d.string("dump") {
    var fds: [[String: Any]] = []
    for fd in 0..<256 where fcntl(Int32(fd), F_GETFD) != -1 {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let known = fcntl(Int32(fd), F_GETPATH, &buffer) != -1
        let path = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        fds.append(["fd": fd, "path": known ? String(decoding: path, as: UTF8.self) : ""])
    }
    // stdin is read to completion: /dev/null (or a closed pipe) returns at once, an open terminal or pipe
    // would block here, which is exactly what the test wants to notice.
    var byte: UInt8 = 0
    let stdinEOF = read(0, &byte, 1) == 0
    let info: [String: Any] = [
        "argv": args, "env": ProcessInfo.processInfo.environment,
        "cwd": FileManager.default.currentDirectoryPath, "fds": fds, "stdin_eof": stdinEOF,
        "pid": getpid(), "pgid": getpgrp(),
    ]
    try? json(info).write(toFile: path, atomically: true, encoding: .utf8)
}

// MARK: session bookkeeping

if let dir = d.string("sessions") {
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let marker = dir + "/" + sessionID
    let exists = FileManager.default.fileExists(atPath: marker)
    if sessionArg != nil, exists { fail("Error: Session ID \(sessionID) is already in use.") }
    if resumeArg != nil, !exists { fail("Error: No conversation found with session ID: \(sessionID)") }
    FileManager.default.createFile(atPath: marker, contents: nil)
}

// MARK: signals and children

if d.has("ignore-term") {
    signal(SIGTERM, SIG_IGN)
} else {
    signal(SIGTERM, terminateHandler)
}

if let pidFile = d.string("grandchild") {
    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
    posix_spawnattr_setpgroup(&attributes, 0)  // its own group, like real tool children (spike S6)
    var pid: pid_t = 0
    let argv: [UnsafeMutablePointer<CChar>?] = [strdup("sleep"), strdup("300"), nil]
    let status = posix_spawn(&pid, "/bin/sleep", nil, &attributes, argv, environ)
    guard status == 0 else { fail("fake-claude: cannot start grandchild (\(status))", code: 70) }
    grandchildPID = pid
    try? String(pid).write(toFile: pidFile, atomically: true, encoding: .utf8)
}

if let path = d.string("ready") {
    FileManager.default.createFile(atPath: path, contents: nil)
}

// MARK: the turn

var lines: [String]
if let fixture = d.string("fixture") {
    guard let text = try? String(contentsOfFile: fixture, encoding: .utf8) else {
        fail("fake-claude: cannot read fixture \(fixture)", code: 70)
    }
    lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    // Recorded runs carry the session id they were recorded with; use the one we were given.
    if let first = lines.first(where: { $0.contains("\"session_id\":\"") }),
        let range = first.range(of: #"(?<="session_id":")[^"]+"#, options: .regularExpression)
    {
        let recorded = String(first[range])
        lines = lines.map { $0.replacingOccurrences(of: recorded, with: sessionID) }
    }
} else {
    lines = [
        json([
            "type": "system", "subtype": "init", "session_id": sessionID, "model": "fake-claude",
            "cwd": FileManager.default.currentDirectoryPath, "tools": [String](), "mcp_servers": [String](),
            "permissionMode": "default", "apiKeySource": "none",
        ])
    ]
    for i in 0..<(d.int("stream-events") ?? 0) {
        lines.append(
            json([
                "type": "stream_event", "session_id": sessionID,
                "event": ["type": "content_block_delta", "index": i],
            ]))
    }
    lines.append(
        json([
            "type": "assistant", "session_id": sessionID,
            "message": ["role": "assistant", "content": [["type": "text", "text": "fake claude: \(prompt)"]]],
        ]))
    if !d.has("no-result") {
        lines.append(
            json([
                "type": "result", "subtype": "success", "is_error": false, "num_turns": 1,
                "duration_ms": 1, "result": "fake claude: \(prompt)", "stop_reason": "end_turn",
                "terminal_reason": "completed", "session_id": sessionID, "total_cost_usd": 0.001,
                "permission_denials": [Any](),
                "usage": ["input_tokens": 1, "output_tokens": 1],
            ]))
    }
}

// Extra lines go before the last one, so the stream still ends the way a real one does.
var extras: [String] = []
if d.has("invalid-line") { extras.append("this is not json {") }
if let size = d.int("flood") {
    extras.append(json(["type": "stream_event", "session_id": sessionID, "blob": String(repeating: "x", count: size)]))
}
if !extras.isEmpty, let last = lines.popLast() {
    lines.append(contentsOf: extras)
    lines.append(last)
}

let delay = d.int("delay-ms") ?? 0
for (index, line) in lines.enumerated() {
    let isLast = index == lines.count - 1
    if isLast, d.has("partial-tail") {
        write(line)
    } else {
        write(line + "\n")
    }

    let emitted = index + 1
    if d.int("hang-after") == emitted { while true { sleep(60) } }
    if d.int("crash-after") == emitted { exit(70) }
    if d.int("die-after") == emitted { kill(getpid(), SIGKILL) }
    if delay > 0, !isLast { usleep(UInt32(delay) * 1000) }
}

exit(Int32(d.int("exit") ?? 0))
