import Foundation

/// `[run]`: how the project's app is started for the verifier (docs/plan/P16-run.md). Workbench starts `command` itself,
/// waits for the ready check and stops it when the turn ends, so the verifier only drives and photographs it. It is
/// launch only: nothing the command prints or returns is a verdict.
public struct RunConfig: Sendable, Equatable {
    public static let defaultReadyTimeoutS = 120
    public static let maxReadyTimeoutS = 900

    /// The start command, one plain command like `check_command`, run in the thread's worktree.
    public var command: String
    /// How Workbench knows the app is up. Exactly one of the two is set.
    public var ready: Ready
    public var readyTimeoutS: Int

    public enum Ready: Sendable, Equatable {
        /// An http URL on this machine, `{port}` standing for `WORKBENCH_PORT`. Any HTTP answer counts as up.
        case url(String)
        /// A regular expression a line of the command's output must match, as Triage's `mock.sh` prints one just
        /// before it opens the app.
        case line(String)
    }

    public init(command: String, ready: Ready, readyTimeoutS: Int = RunConfig.defaultReadyTimeoutS) {
        self.command = command
        self.ready = ready
        self.readyTimeoutS = readyTimeoutS
    }

    static let table = "run"
    static let keys: Set<String> = ["command", "ready_url", "ready_line", "ready_timeout_s"]

    static func owns(table name: String) -> Bool { name == table }

    /// Why a ready URL cannot be used, nil when it can. Only this machine: the check must not reach out.
    static func urlProblem(_ value: String) -> String? {
        guard let url = URL(string: value.replacingOccurrences(of: "{port}", with: "1")),
            let scheme = url.scheme, scheme == "http", let host = url.host, url.port != nil
        else { return "must be an http URL with a port, such as \"http://localhost:{port}/\"" }
        guard ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host) else {
            return "must point at this machine (localhost or 127.0.0.1), not '\(host)'"
        }
        return nil
    }

    /// Nil when the project declares no `[run]`; a table with problems also gives nil, after `fail` has been told.
    static func parse(_ document: TOMLDocument, fail: ReviewConfig.Fail) -> RunConfig? {
        guard let table = document.tables[table] else { return nil }
        for (key, entry) in table.entries.sorted(by: { $0.key < $1.key }) where !keys.contains(key) {
            fail(.unknownKey, entry.line, "unknown key '\(key)' in [run]")
        }
        var ok = true

        func string(_ key: String) -> (value: String, line: Int)? {
            guard let entry = table.entries[key] else { return nil }
            guard case .string(let value) = entry.value else {
                fail(.wrongType, entry.line, "'\(key)' must be a string, found \(entry.value.typeName)")
                ok = false
                return nil
            }
            return (value, entry.line)
        }

        var command = ""
        if let (value, line) = string("command") {
            if let reason = Config.checkCommandProblem(value) {
                fail(.invalidValue, line, "'command' \(reason)")
                ok = false
            }
            command = value
        } else if table.entries["command"] == nil {
            fail(.invalidValue, table.line, "[run] needs a 'command'")
            ok = false
        }

        let url = string("ready_url")
        let line = string("ready_line")
        var ready: Ready?
        switch (url, line) {
        case (let url?, nil):
            if let reason = urlProblem(url.value) {
                fail(.invalidValue, url.line, "'ready_url' \(reason)")
                ok = false
            }
            ready = .url(url.value)
        case (nil, let line?):
            if line.value.isEmpty || (try? NSRegularExpression(pattern: line.value)) == nil {
                fail(.invalidValue, line.line, "'ready_line' must be a valid, non-empty regular expression")
                ok = false
            }
            ready = .line(line.value)
        case (.some, .some):
            fail(.invalidValue, table.line, "[run] takes 'ready_url' or 'ready_line', not both")
            ok = false
        case (nil, nil):
            if table.entries["ready_url"] == nil, table.entries["ready_line"] == nil {
                fail(.invalidValue, table.line, "[run] needs 'ready_url' or 'ready_line'")
            }
            ok = false
        }

        var timeout = defaultReadyTimeoutS
        if let entry = table.entries["ready_timeout_s"] {
            if case .int(let n) = entry.value, (1...maxReadyTimeoutS).contains(n) {
                timeout = n
            } else {
                fail(
                    .invalidValue, entry.line,
                    "'ready_timeout_s' must be a whole number of seconds from 1 to \(maxReadyTimeoutS)")
                ok = false
            }
        }

        guard ok, let ready else { return nil }
        return RunConfig(command: command, ready: ready, readyTimeoutS: timeout)
    }
}
