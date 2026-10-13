import Foundation
import WorkbenchCore

/// Everything a command needs, resolved once from the current directory.
struct Context {
    let project: Project
    let git: GitRunner
    let store: ThreadStore
    let service: ThreadService

    static func load() async throws -> Context {
        let git = try GitRunner.discover()
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let project = try await Project.locate(from: cwd, git: git)
        return Context(
            project: project, git: git, store: ThreadStore(project: project),
            service: ThreadService(project: project, git: git))
    }

    /// The thread a command means: the one named, or else the active one.
    func threadID(_ named: String?) throws -> String {
        if let named {
            guard FileManager.default.fileExists(atPath: project.threadDirectory(named).path) else {
                throw CLIError.message("no thread '\(named)'")
            }
            return named
        }
        guard let active = store.activeThreadID() else { throw ThreadStoreError.noActiveThread }
        return active
    }

    /// For read-only commands: the active thread, or else the most recently created one.
    func threadIDForViewing(_ named: String?) throws -> String {
        if let named { return try threadID(named) }
        if let active = store.activeThreadID() { return active }
        let latest = store.threadIDs().map { store.state(of: $0) }.max { ($0.createdAt ?? "") < ($1.createdAt ?? "") }
        guard let latest else { throw ThreadStoreError.noActiveThread }
        return latest.id
    }
}

enum CLIError: Error, CustomStringConvertible {
    case message(String)
    case usage(String)

    var description: String {
        switch self {
        case .message(let m), .usage(let m): m
        }
    }
}

func out(_ text: String = "") { print(text) }

func err(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

/// Pulls `--flag value` and `--flag` out of the arguments; what is left is positional.
struct Arguments {
    private(set) var rest: [String]

    init(_ arguments: [String]) { rest = arguments }

    mutating func flag(_ names: String...) -> Bool {
        guard let i = rest.firstIndex(where: { names.contains($0) }) else { return false }
        rest.remove(at: i)
        return true
    }

    mutating func value(_ names: String...) throws -> String? {
        guard let i = rest.firstIndex(where: { names.contains($0) }) else { return nil }
        guard i + 1 < rest.count else { throw CLIError.usage("\(rest[i]) needs a value") }
        let value = rest[i + 1]
        rest.removeSubrange(i...(i + 1))
        return value
    }

    mutating func positional() -> String? {
        guard let first = rest.first, !first.hasPrefix("-") else { return nil }
        rest.removeFirst()
        return first
    }

    func requireEmpty() throws {
        if let extra = rest.first { throw CLIError.usage("unexpected argument '\(extra)'") }
    }
}

// MARK: - Commands

enum Commands {
    static func initProject() async throws {
        let ctx = try await Context.load()
        try FileManager.default.createDirectory(
            at: ctx.project.workbenchDirectory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: ctx.project.configURL.path) {
            out("config already exists: \(ctx.project.configURL.path)")
        } else {
            try Config.exampleTOML.write(to: ctx.project.configURL, atomically: true, encoding: .utf8)
            out("wrote \(ctx.project.configURL.path)")
            out("review the tool set, then: workbench goal new <name>")
        }
    }

    static func goalNew(_ args: [String]) async throws {
        var a = Arguments(args)
        let base = try a.value("--base")
        guard let name = a.positional() else { throw CLIError.usage("usage: workbench goal new <name> [--base <branch>]") }
        try a.requireEmpty()

        let ctx = try await Context.load()
        let config = try? Config.load(from: ctx.project.configURL)
        let id = try await ctx.service.newThread(name: name, base: base, config: config)
        out("created \(id)")
        out("edit:    \(ctx.project.goalURL(id).path)")
        out("then:    workbench goal approve")
        if config == nil { out("note: no .workbench/config.toml yet; run `workbench init`") }
    }

    static func goalApprove(_ args: [String]) async throws {
        var a = Arguments(args)
        let named = a.positional()
        try a.requireEmpty()
        let ctx = try await Context.load()
        let id = try ctx.threadID(named)

        let before = try? GoalFile.parse(String(contentsOf: ctx.project.goalURL(id), encoding: .utf8))
        let approved = try await ctx.service.approve(id: id)
        if before?.goal.approval == .approved {
            out("\(id) is already approved (\(approved.goal.contentHash.prefix(12)))")
        } else {
            out("approved \(id)")
            out("hash:    \(approved.goal.contentHash.prefix(12))")
            out("budget:  $\(approved.goal.budgetUSD) per turn, timeout \(approved.goal.turnTimeoutMin) min")
            out("next:    workbench run")
        }
    }

    static func run(_ args: [String]) async throws -> Int32 {
        var a = Arguments(args)
        let feedback = try a.value("--feedback", "-f")
        let allowDirty = a.flag("--allow-dirty")
        let named = a.positional()
        try a.requireEmpty()

        let ctx = try await Context.load()
        let id = try ctx.threadID(named)

        let runner = ThreadRunner(project: ctx.project, threadID: id, git: ctx.git) { notice in
            switch notice {
            case .recoveredOrphanedTurn(let turn):
                out("recovered: turn \(turn) was left open by a runner that died; recorded as interrupted")
            case .recoveredOrphanedCheck(let turn):
                out("recovered: the check after turn \(turn) was left open by a runner that died; recorded as interrupted")
            case .sweptOrphans(let pids):
                out("swept \(pids.count) leftover process(es) from an earlier run")
            case .turnStarted(let turn, let pid, let resume):
                out("turn \(turn) started\(pid.map { " (pid \($0))" } ?? ""), \(resume ? "resuming session" : "new session")")
            case .claudeLine(let line):
                if let data = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)),
                    let text = LogFormatter.describeClaude(data) {
                    out("  \(text)")
                }
            case .turnEnded(let report):
                out("turn \(report.turn) ended: \(report.result.rawValue)"
                    + (report.costUSD.map { String(format: "  $%.4f", $0) } ?? "")
                    + "  \(report.durationMs / 1000)s"
                    + (report.permissionDenials > 0 ? "  \(report.permissionDenials) denied" : ""))
            case .checkStarted(_, let command):
                out("check started: \(command)")
            case .checkRan(let check):
                out(LogFormatter.describeCheck(
                        result: check.result.rawValue, exitCode: check.exitCode.map { Int($0) },
                        signal: check.signal.map { Int($0) })
                    + "  \(check.durationMs / 1000)s"
                    + (check.outputTruncated ? "  output truncated" : "")
                    + "  (\(ctx.project.threadDirectory(id).appendingPathComponent(check.outputRef).path))")
            }
        }

        // Ctrl-C and SIGTERM stop the turn or check cleanly: it still ends with a recorded `stopped`.
        let signals = installStopHandlers(for: runner)
        defer { signals.forEach { $0.cancel() } }

        var options = RunOptions(feedback: feedback)
        options.allowDirty = allowDirty
        let report = try await runner.run(options)
        if let summary = report.summary, report.result == .succeeded {
            out()
            out(summary)
        }
        out()
        out("review:  workbench log    (worktree: \(ctx.project.worktreesDirectory.appendingPathComponent(id).path))")
        switch report.result {
        case .succeeded: return 0
        case .failed, .interrupted: return 1
        case .stopped: return 3
        case .timedOut: return 4
        case .budgetExceeded: return 5
        }
    }

    static func stop(_ args: [String]) async throws {
        var a = Arguments(args)
        let named = a.positional()
        try a.requireEmpty()
        let ctx = try await Context.load()
        let id = try ctx.threadID(named)
        switch ctx.service.requestStop(id: id) {
        case .signalled(let pid): out("asked the run (pid \(pid)) to stop; it will record the turn as stopped")
        case .notRunning: out("nothing is running for \(id)")
        }
    }

    static func log(_ args: [String]) async throws {
        var a = Arguments(args)
        let follow = a.flag("--follow", "-f")
        let verbose = a.flag("--verbose", "-v", "--raw")
        let named = a.positional()
        try a.requireEmpty()
        let ctx = try await Context.load()
        let id = try ctx.threadIDForViewing(named)
        let url = ctx.project.eventsURL(id)

        func show(_ event: Event) {
            if event.kind == .claude, !verbose, LogFormatter.describeClaude(event.data) == nil { return }
            // One line per check: how it ended.
            if event.kind == .checkStarted, !verbose { return }
            out(LogFormatter.describe(event))
        }

        var printed = 0
        var contents = try EventLogReader.read(at: url)
        // Already in the middle of a turn or of its check: follow until that ends.
        let startedWithOpenTurn = contents.openTurn != nil || contents.openCheck != nil
        for event in contents.events {
            show(event)
            printed += 1
        }
        guard follow else { return }

        // A turn is followed to the end of its check, when one will run.
        let checks = (try? Config.load(from: ctx.project.configURL))?.checkCommand != nil
        var sawStart = startedWithOpenTurn
        while true {
            try await Task.sleep(nanoseconds: 300_000_000)
            contents = try EventLogReader.read(at: url)
            for event in contents.events.dropFirst(printed) {
                show(event)
                if event.kind == .turnStarted { sawStart = true }
                let result = event.data["result"]?.stringValue
                let checkFollows = checks && result != "stopped" && result != "interrupted"
                if event.kind == .turnEnded, sawStart, !checkFollows { return }
                if event.kind == .checkRan, sawStart { return }
            }
            printed = contents.events.count
        }
    }

    static func status(_ args: [String]) async throws {
        var a = Arguments(args)
        let named = a.positional()
        try a.requireEmpty()
        let ctx = try await Context.load()

        guard let id = try? ctx.threadIDForViewing(named) else {
            out("no threads yet. Start one: workbench goal new <name>")
            return
        }
        let state = ctx.store.state(of: id)
        out("thread:    \(id)\(state.isActive ? "" : "  (ended: \(state.decision ?? "?"))")")

        if let text = try? String(contentsOf: ctx.project.goalURL(id), encoding: .utf8) {
            do {
                let goal = try GoalFile.parse(text).goal
                out("title:     \(goal.title)")
                let approval: String
                switch goal.approval {
                case .approved: approval = "approved"
                case .draft: approval = "draft (run `workbench goal approve`)"
                case .stale: approval = "CHANGED since approval, back to draft (run `workbench goal approve`)"
                }
                out("goal:      \(approval)")
                out("base:      \(goal.base)   budget $\(goal.budgetUSD)/turn   timeout \(goal.turnTimeoutMin) min")
            } catch let error as GoalParseError {
                let problems = error.description.split(separator: "\n").map { "           \($0)" }
                out("goal:      not valid\n\(problems.joined(separator: "\n"))")
            }
        }

        let running = ctx.service.runnerPID(id: id) != nil
        var turns = "turns:     \(state.lastTurn)"
        if let open = state.openTurn {
            let note = running ? "running" : "NOT running: will be recorded as interrupted on next run"
            turns += "  (turn \(open) open, \(note))"
        }
        out(turns)
        if let result = state.lastResult { out("last turn: \(result)") }
        if let open = state.openCheck {
            let note = running ? "running" : "NOT running: will be recorded as interrupted on next run"
            out("check:     turn \(open) open, \(note)")
        } else if let check = state.lastCheck {
            out("check:     \(check)")
        }
        out(String(format: "cost:      $%.4f (list price; not what a subscription charges)", state.totalCostUSD))
        let worktree = ctx.project.worktreesDirectory.appendingPathComponent(id)
        if FileManager.default.fileExists(atPath: worktree.path) { out("worktree:  \(worktree.path)") }
    }

    static func abandon(_ args: [String]) async throws {
        var a = Arguments(args)
        let force = a.flag("--force")
        let named = a.positional()
        try a.requireEmpty()
        let ctx = try await Context.load()
        let id = try ctx.threadID(named)
        try await ctx.service.abandon(id: id, force: force)
        out("abandoned \(id); its branch workbench/\(id) is kept")
    }

    static func config() async throws {
        let ctx = try await Context.load()
        let config = try Config.load(from: ctx.project.configURL)
        let turn = TurnRequest(
            sessionID: UUID(), resume: false, budgetUSD: config.defaultBudgetUSD, prompt: "<prompt>")
        let invocation = try config.invocation(for: turn)
        let env = ProcessInfo.processInfo.environment
        let resolved = ExecutableResolver.resolve(config.claudePath, searchPath: env["PATH"])
        out("config:   \(ctx.project.configURL.path)")
        out("claude:   \(resolved?.path ?? "NOT FOUND on PATH (\(config.claudePath))")")
        out("check:    \(config.checkCommand ?? "(none)")")
        out("budget:   \(config.defaultBudgetUSD) USD default")
        out("tools:    \(config.tools.available.joined(separator: ", "))")
        out("allowed:  \(config.effectiveAllowedTools.joined(separator: ", "))")
        out("denied:   \(config.tools.denied.joined(separator: ", "))")
        out("env:      \(config.childEnvironment(from: env).keys.sorted().joined(separator: ", "))")
        out("command:  \(invocation.displayCommand)")
    }
}

// MARK: - Signals

/// SIGINT and SIGTERM ask the running turn to stop. The default action would kill this process and leave
/// the turn open until the next run recovers it; this way it ends as `stopped`.
func installStopHandlers(for runner: ThreadRunner) -> [DispatchSourceSignal] {
    var sources: [DispatchSourceSignal] = []
    for sig in [SIGINT, SIGTERM] {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler {
            err("\nstopping: ending the turn cleanly (press Ctrl-C again to quit immediately)")
            Task { await runner.stop() }
            signal(sig, SIG_DFL)  // a second press takes the default action
        }
        source.resume()
        sources.append(source)
    }
    return sources
}
