import Foundation

/// Why a `herdr-app` call did not give an answer: its own error (a sentence), or one of ours.
public struct HerdrFailure: Error, Equatable, Sendable, CustomStringConvertible {
    public var code: String?
    public var message: String
    public var description: String { message }

    public init(code: String? = nil, message: String) {
        self.code = code
        self.message = message
    }

    /// Herdr's window is not open (its socket is not there); nothing else.
    public var windowDown: Bool { code == "no_window" }
}

/// One `herdr-app` command at a time, through core's process layer: bounded time, bounded output, its group swept on a timeout. The
/// app answers each command with a JSON document on stdout (pretty-printed, several lines), or exits 1 with `{"error": "<sentence>"}`
/// there; with no window open it exits 2 and says "no Herdr window" on stderr.
public struct HerdrClient: Sendable {
    public var executable: URL
    public var environment: [String: String]
    public var timeout: TimeInterval

    public init(executable: URL, environment: [String: String] = [:], timeout: TimeInterval = 10) {
        self.executable = executable
        self.environment = environment
        self.timeout = timeout
    }

    /// What `herdr-app` needs from the window's environment to find its window (`HERDR_APP_HOME` moves it), and nothing else.
    public static func environment(from parent: [String: String]) -> [String: String] {
        let names: Set<String> = ["HOME", "USER", "LOGNAME", "PATH", "TMPDIR", "LANG", "SHELL", "HERDR_APP_HOME"]
        return parent.filter { names.contains($0.key) || $0.key.hasPrefix("LC_") || $0.key.hasPrefix("XDG_") }
    }

    /// The answer of one command. Throws `HerdrFailure` for an error answer, a hang, or an answer that is not JSON.
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
            case .line(let line): if lines.count < 2000 { lines.append(line) }
            case .exited(let ended): exit = ended
            default: break
            }
        }
        guard let exit else { throw HerdrFailure(code: "no_exit", message: "herdr ended without saying how") }
        if exit.cause == .timedOut {
            throw HerdrFailure(
                code: "timeout", message: "herdr-app did not answer within \(Int(timeout)) seconds and was stopped")
        }
        if case .exited(0) = exit.termination {
            guard let answer = Self.parse(lines.joined(separator: "\n")) else {
                throw HerdrFailure(code: "bad_answer", message: "herdr-app answered with something that is not JSON")
            }
            return answer
        }
        throw Self.failure(stderr: exit.stderrTail, stdout: lines)
    }

    /// The `{"error": "<sentence>"}` the command wrote, "no Herdr window" from stderr, else the last printable line.
    static func failure(stderr: String, stdout: [String]) -> HerdrFailure {
        if let message = parse(stdout.joined(separator: "\n"))?["error"]?.stringValue {
            return HerdrFailure(code: "refused", message: ThreadState.safeLine(message, limit: 200))
        }
        let errLines = stderr.split(whereSeparator: \.isNewline).map(String.init)
        if errLines.contains(where: { $0.contains("no Herdr window") }) {
            return HerdrFailure(code: "no_window", message: "Herdr's window is not open")
        }
        let last = (errLines + stdout).reversed().first { !$0.allSatisfy(\.isWhitespace) }
        return HerdrFailure(
            code: "failed", message: last.map { ThreadState.safeLine($0, limit: 200) } ?? "herdr-app failed without a message")
    }

    static func parse(_ text: String) -> JSONValue? {
        try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }
}

/// What opening a folder in Herdr did.
public struct HerdrOpened: Equatable, Sendable {
    /// The space Herdr shows the folder in.
    public var space: String
    /// The folder already had a space: it was brought forward, not made.
    public var alreadyOpen: Bool
}

/// What handing a goal to Herdr did.
public struct HerdrHandoff: Equatable, Sendable {
    /// The space Herdr shows the worktree in.
    public var space: String
    /// The worktree already had a space: it was brought forward and nothing was typed into it.
    public var alreadyOpen: Bool

    public init(space: String, alreadyOpen: Bool) {
        self.space = space
        self.alreadyOpen = alreadyOpen
    }
}

/// "Open in Herdr": starts the Herdr app when its window is not open, then gives the thread's worktree a space (or selects the one it
/// has) and brings the app forward. The app's own server comes up with its window, so there is nothing else to start.
public struct HerdrOpener: Sendable {
    public var client: HerdrClient
    /// Starts the Herdr app, or brings a running one forward; the window's launcher, not a process of core's.
    public var launchApp: @Sendable () async throws -> Void
    /// How long to wait for the window after starting the app, and how often to ask.
    public var startupWait: TimeInterval = 20
    public var pollInterval: TimeInterval = 0.5

    public init(client: HerdrClient, launchApp: @escaping @Sendable () async throws -> Void) {
        self.client = client
        self.launchApp = launchApp
    }

    public func open(folder: URL, label: String) async throws -> HerdrOpened {
        let space = try await openSpace(folder: folder, label: label)
        // A running app does not come forward by itself when a space is added; a launch already did. Best effort: the space is open.
        if !space.wasDown { try? await launchApp() }
        return space.opened
    }

    /// Herdr's window, started when it is not open. True when it was down. Called before anything is changed for Herdr, so a
    /// machine where it cannot come up changes nothing.
    @discardableResult
    public func ensureWindow() async throws -> Bool {
        do {
            _ = try await listSpaces()
            return false
        } catch let failure as HerdrFailure where failure.windowDown {
            try await launchApp()
            _ = try await waitForWindow()
            return true
        }
    }

    /// "Run in Herdr": opens the worktree as a space like `open`, and starts `argv` as the first terminal of a space it made (`space.new
    /// --argv`; this `herdr-app` has no command that types into a terminal). A space the worktree already had is only brought
    /// forward: a session already working there is not given the goal a second time.
    public func handOff(folder: URL, label: String, argv: [String]) async throws -> HerdrHandoff {
        let space = try await openSpace(folder: folder, label: label, argv: argv)
        if !space.wasDown { try? await launchApp() }
        return HerdrHandoff(space: space.opened.space, alreadyOpen: space.opened.alreadyOpen)
    }

    /// What is started in the space's terminal: `claude` with a fixed prompt that points at the goal copy, so nothing from the goal
    /// itself reaches a shell, stopped with everything it started after the goal's `turn_timeout_min`. `marker` is the thread's
    /// `runner.json`: the session holds the thread while it runs, so a run, a discard or the orphan sweep leaves it alone.
    public static func claudeArguments(turnTimeoutMin: Int, marker: URL) -> [String] {
        claudeArguments(timeoutSeconds: max(1, turnTimeoutMin) * 60, marker: marker)
    }

    /// A Perl supervisor runs claude as its child, in the shell's foreground group so it keeps the terminal. It writes the marker,
    /// then every second records the tree below it (pid and group). At the timeout, on a SIGTERM, and when claude ends by itself, it
    /// sends SIGTERM to what it recorded and to the process groups they led or joined, waits `graceSeconds`, then SIGKILLs what it
    /// recorded (a pid only while it is still in the group it was seen in, so a reused pid is spared) and what is there now. A tool
    /// child whose parent died before the next look is not found; one that was seen once is.
    static func claudeArguments(timeoutSeconds: Int, graceSeconds: Int = 10, marker: URL) -> [String] {
        [
            "/usr/bin/perl", "-MPOSIX=WNOHANG", "-e", supervisor, String(timeoutSeconds), String(graceSeconds), marker.path,
            "claude",
            "Read \(WorktreeManager.goalCopyPath): it is the approved goal for this worktree. "
                + "Work on it here until every criterion holds, and commit your work.",
        ]
    }

    private static let supervisor = [
        #"my ($t, $w, $m) = splice @ARGV, 0, 3; my $me = $$; my $at = time;"#,
        // The marker's start time is read after the process began; `runnerPID` accepts it within a couple of seconds.
        #"if (open my $f, ">", $m) { print $f qq({"pid":$me,"session":"herdr","started_seconds":$at}); close $f }"#,
        #"END { unlink $m if $$ == $me }"#,
        #"defined(my $c = fork) or die "claude: $!$/";"#,
        #"unless ($c) { exec @ARGV or die "claude: $!$/" }"#,
        // Ctrl-C reaches the whole foreground group; it is claude's to handle, and must not take the supervisor away.
        #"$SIG{$_} = "IGNORE" for qw(INT QUIT);"#,
        #"sub table { my %g; my %k; for (`/bin/ps -A -o pid= -o ppid= -o pgid=`) { my ($p, $q, $r) = split; "#
            + #"next unless defined $r; $g{$p} = $r; push @{$k{$q}}, $p } return (\%g, \%k) }"#,
        // %seen: pid => its group at the last look; %groups: the groups of what was seen, never the shell's own.
        #"my (%seen, %groups);"#,
        #"sub look { my ($g, $k) = table(); my @todo = ($$); my @found; "#
            + #"while (@todo) { for (@{$k->{shift @todo} || []}) { push @found, $_; push @todo, $_ } } "#,
        #"my %skip = (getpgrp() => 1, ($g->{getppid()} // 0) => 1, 0 => 1, 1 => 1); "#
            + #"for (@found) { $seen{$_} = $g->{$_}; $groups{$g->{$_}} = 1 unless $skip{$g->{$_}} } return $g }"#,
        #"sub hit { my ($s, $pids, $groups) = @_; kill $s, @$pids if @$pids; kill $s, map { -$_ } @$groups if @$groups }"#,
        #"sub clean { look(); my %was = %seen; hit("TERM", [keys %was], [keys %groups]); "#
            + #"for (1 .. $w * 10) { waitpid $c, WNOHANG; last unless kill 0, keys %was; select undef, undef, undef, 0.1 } "#,
        #"my ($now) = table(); my @left = grep { ($now->{$_} // -1) == $was{$_} } keys %was; "#
            + #"look(); hit("KILL", [@left, grep { !exists $was{$_} } keys %seen], [keys %groups]) }"#,
        // A request to stop (the app's Stop sends SIGTERM to the pid in the marker) stops claude and what it started, not only this.
        #"$SIG{TERM} = sub { $SIG{TERM} = "IGNORE"; print STDERR $/, "claude: stopped on request", $/; "#
            + #"clean(); waitpid $c, 0; exit 143 };"#,
        #"my $end = $at + $t; my $r;"#,
        #"until (($r = waitpid $c, WNOHANG) == $c) { look(); "#
            + #"if (time >= $end) { last if waitpid($c, WNOHANG) == $c; "#
            + #"print STDERR $/, "claude: stopped after $t seconds, the goal turn_timeout_min", $/; "#
            + #"clean(); waitpid $c, 0; exit 124 } select undef, undef, undef, 1 }"#,
        #"my $status = $?; clean();"#,
        #"exit($status & 127 ? 128 + ($status & 127) : $status >> 8);"#,
    ].joined(separator: " ")

    /// The space showing `folder`, selected or made; the terminal Herdr names for a space it made; and whether the app was started.
    private struct OpenedSpace {
        var opened: HerdrOpened
        var wasDown: Bool
    }

    private func openSpace(folder: URL, label: String, argv: [String]? = nil) async throws -> OpenedSpace {
        var spaces: [JSONValue]
        let wasDown: Bool
        do {
            spaces = try await listSpaces()
            wasDown = false
        } catch let failure as HerdrFailure where failure.windowDown {
            try await launchApp()
            spaces = try await waitForWindow()
            wasDown = true
        }
        if let existing = space(showing: folder, in: spaces) {
            _ = try await client.call(["do", "space.select", "--id", existing])
            return OpenedSpace(opened: HerdrOpened(space: existing, alreadyOpen: true), wasDown: wasDown)
        }
        var arguments = ["do", "space.new", "--name", label, "--folder", folder.path]
        if let argv {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .withoutEscapingSlashes
            guard let json = try? encoder.encode(argv), let text = String(data: json, encoding: .utf8) else {
                throw HerdrFailure(code: "bad_argv", message: "the command to start could not be encoded")
            }
            arguments += ["--argv", text]
        }
        let made = try await client.call(arguments)
        return OpenedSpace(opened: HerdrOpened(space: made["space"]?.stringValue ?? "", alreadyOpen: false), wasDown: wasDown)
    }

    /// Down only when the app says it has no window. Any other failure (a hang, an error of its own) is thrown as it is: starting
    /// the app on top of it would lose what Herdr said and wait twice.
    func listSpaces() async throws -> [JSONValue] {
        let result = try await client.call(["ls"])
        guard case .array(let spaces)? = result["spaces"] else { return [] }
        return spaces
    }

    func waitForWindow() async throws -> [JSONValue] {
        let deadline = Date().addingTimeInterval(startupWait)
        while Date() < deadline {
            do { return try await listSpaces() } catch let failure as HerdrFailure where failure.windowDown {}
            try await Task.sleep(for: .seconds(pollInterval))
        }
        throw HerdrFailure(
            code: "no_window", message: "Herdr was started but its window did not come up within \(Int(startupWait)) seconds")
    }

    /// The space whose folder is `folder`.
    func space(showing folder: URL, in spaces: [JSONValue]) -> String? {
        let wanted = folder.resolvingSymlinksInPath().path
        return spaces.first { space in
            guard let path = space["folder"]?.stringValue else { return false }
            return URL(fileURLWithPath: path).resolvingSymlinksInPath().path == wanted
        }?["id"]?.stringValue
    }
}
