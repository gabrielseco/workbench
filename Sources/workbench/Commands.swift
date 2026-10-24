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
                throw CLIError.notFound("no thread '\(named)'")
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
    /// A failure that is not one of the others.
    case message(String)
    case usage(String)
    /// A precondition is not met and nothing was changed (no terminal to ask on, say).
    case refused(String)
    case notFound(String)

    var description: String {
        switch self {
        case .message(let m), .usage(let m), .refused(let m), .notFound(let m): m
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
            out("review the tool set, set check_command and setup_command, then: workbench doctor")
            out("then: workbench goal new <name> (doctor can also run after goal approve, before run)")
        }
        // Keeps `.workbench/` out of the repository's `git status` without touching its .gitignore.
        do {
            try await WorktreeManager(repoRoot: ctx.project.root, git: ctx.git).excludeWorkbench()
        } catch {
            throw CLIError.message(
                "the config is in place, but .workbench/ could not be kept out of `git status` "
                    + "(\(error)). Add `.workbench/` to .git/info/exclude yourself.")
        }
    }

    /// `new <name|path> [--in <dir>] [--seed <path>]... [--nested]`: creates a project; runs only git and copies.
    static func newProject(_ args: [String]) async throws {
        var a = Arguments(args)
        let directory = try a.value("--in")
        var seeds: [String] = []
        while let seed = try a.value("--seed") { seeds.append(seed) }
        let nested = a.flag("--nested")
        guard let given = a.positional() else {
            throw CLIError.usage("usage: workbench new <name|path> [--in <dir>] [--seed <path>]... [--nested]")
        }
        try a.requireEmpty()

        let environment = ProcessInfo.processInfo.environment
        let home = environment["HOME"] ?? NSHomeDirectory()
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        func resolve(_ path: String) -> URL {
            if path == "~" { return URL(fileURLWithPath: home) }
            if path.hasPrefix("~/") { return URL(fileURLWithPath: home).appendingPathComponent(String(path.dropFirst(2))) }
            return URL(fileURLWithPath: path, relativeTo: cwd).absoluteURL
        }

        let globalURL = GlobalConfig.defaultURL(environment: environment)
        let defaults = try GlobalConfig.load(from: globalURL, home: home)

        // Precedence: an explicit path, then --in, then projects_dir. Never the current directory.
        let name: String
        let parent: URL
        if given.contains("/") || given.hasPrefix("~") {
            if directory != nil { err("note: --in is ignored because a path was given") }
            let full = resolve(given).standardizedFileURL
            name = full.lastPathComponent
            parent = full.deletingLastPathComponent()
        } else if let directory {
            name = given
            parent = resolve(directory).standardizedFileURL
        } else if let projects = defaults.projectsDirectory {
            name = given
            parent = projects
        } else {
            throw CLIError.usage(
                "no location: pass a path, --in <dir>, or set projects_dir in \(globalURL.path)")
        }

        let git = try GitRunner.discover()
        let seedURLs = seeds.map { resolve($0) }
        do {
            let root = try await ProjectCreator(git: git).create(
                NewProjectRequest(name: name, parent: parent, seeds: seedURLs, nested: nested, defaults: defaults))
            out("created \(root.path)")
            if !seeds.isEmpty { out("seeded vendor/ with \(seeds.count) path\(seeds.count == 1 ? "" : "s")") }
            out("next: cd \(root.path) && workbench goal new <name>")
            out("      (set check_command and setup_command in .workbench/config.toml first, then `workbench doctor`)")
        } catch let error as NewProjectError {
            switch error {
            case .invalidName, .seedHasSymlink, .seedCollision, .seedTooLarge, .seedUnreadable, .seedOverlapsTarget:
                throw CLIError.usage("\(error)")
            case .seedNotFound: throw CLIError.notFound("\(error)")
            case .targetNotEmpty, .targetNotADirectory, .insideRepository: throw CLIError.refused("\(error)")
            case .gitFailed: throw CLIError.message("\(error)")
            }
        }
    }

    /// `doctor [--base <branch>] [--editor <name-or-command>]`: runs the declared setup and check in a throwaway worktree.
    static func doctor(_ args: [String]) async throws -> Int32 {
        var a = Arguments(args)
        let base = try a.value("--base")
        let editor = try a.value("--editor")
        try a.requireEmpty()
        if let editor, let reason = Editor.valueProblem(editor) { throw CLIError.usage("--editor \(reason)") }
        let ctx = try await Context.load()
        let doctor = Doctor(project: ctx.project, git: ctx.git)
        var options = Doctor.Options()
        options.editor = editor
        let resolved: String
        if let base { resolved = base } else { resolved = await ctx.service.defaultBase() }

        let handlers = installStopHandlers(what: "the doctor run") { doctor.stop() }
        defer { handlers.forEach { $0.cancel() } }
        if !Output.json { out("base:     \(resolved)") }
        let report: DoctorReport
        do { report = try await doctor.run(base: resolved, options: options) } catch let error as DoctorError {
            switch error {
            case .invalidBase: throw CLIError.usage("\(error)")
            case .noConfig, .runnerLive, .alreadyRunning: throw CLIError.refused("\(error)")
            }
        }
        let verdict = report.verdict
        if Output.json {
            // A stop is the usual error object; any other result is the one report object (a checkout left behind is
            // its `cleanup_problem`), with the exit code the text mode has.
            if verdict == .stopped { return fail(.stopped, "doctor was stopped; the worktree was removed") }
            printJSON(doctorJSON(report))
            return verdict == .passed ? 0 : FailureKind.failed.code
        }
        printDoctor(report)
        switch verdict {
        case .cleanupFailed(let problem): return fail(.failed, problem)
        case .stopped: return fail(.stopped, "doctor was stopped; the worktree was removed")
        case .stepsFailed: return fail(.failed, "the declared setup or check did not pass")
        case .passed: return 0
        }
    }

    static func goalNew(_ args: [String]) async throws {
        var a = Arguments(args)
        let base = try a.value("--base")
        let updating = try a.value("--update")
        let from = try a.value("--from")
        guard let name = a.positional() else {
            throw CLIError.usage(
                "usage: workbench goal new <name> [--base <branch> | --update <branch>] [--from <goal-file>]")
        }
        try a.requireEmpty()
        let copy = try from.map { try ThreadService.goalCopy(copying: URL(fileURLWithPath: $0)) }

        let ctx = try await Context.load()
        let config = try? Config.load(from: ctx.project.configURL)
        let id = try await ctx.service.newThread(
            name: name, base: base, updating: updating, config: config, body: copy?.body,
            settings: copy?.settings ?? GoalSettings())
        out("created \(id)")
        if let ignored = copy?.ignoredKeys, !ignored.isEmpty {
            out("ignored from the file: \(ignored.joined(separator: ", "))")
        }
        if let base = try? GoalFile.parse(String(contentsOf: ctx.project.goalURL(id), encoding: .utf8)).goal.base {
            out("base:    \(base)")
        }
        out("edit:    \(ctx.project.goalURL(id).path)")
        out("then:    workbench goal approve")
        if config == nil { out("note: no .workbench/config.toml yet; run `workbench init`") }
    }

    static func goalApprove(_ args: [String]) async throws {
        var a = Arguments(args)
        let allowUnrunnable = a.flag("--allow-unrunnable-proofs")
        let named = a.positional()
        try a.requireEmpty()
        let ctx = try await Context.load()
        let id = try ctx.threadID(named)

        let before = try? GoalFile.parse(String(contentsOf: ctx.project.goalURL(id), encoding: .utf8))
        // Nothing is approved while a proof cannot run (friction #30); a goal that does not parse is left to
        // `approve` to report.
        // A config that is there but broken is an error here, not a reason to skip the check; no config at all
        // means there is no tool set to judge against.
        if let before, !allowUnrunnable, FileManager.default.fileExists(atPath: ctx.project.configURL.path) {
            let config = try Config.load(from: ctx.project.configURL)
            let skill = await skillAvailable(config, ctx, before.goal.base)
            let unrunnable = ProofCommands.warnings(goal: before.goal, config: config, verifierSkillAvailable: skill)
            if !unrunnable.isEmpty { throw CLIError.refused(ProofWarning.refusal(unrunnable)) }
        }
        let approved = try await ctx.service.approve(id: id)
        let binding = ThreadStore(project: ctx.project).state(of: id).approvedAgent
        if before?.goal.approval == .approved {
            out("\(id) is already approved (\(approved.goal.contentHash.prefix(12)))")
            if let binding { out("coding:  \(binding.description)") }
        } else {
            defer { if let binding { out("coding:  \(binding.description)") } }
            out("approved \(id)")
            out("hash:    \(approved.goal.contentHash.prefix(12))")
            out(approved.goal.isTimeoutOnly ? "spend:   \(approved.goal.spendLine)" : "budget:  \(approved.goal.spendLine)")
            if let model = approved.goal.model { out("model:   \(model)") }
            if let pushTo = approved.goal.pushTo { out("push to: \(pushTo)") }
        }
        if allowUnrunnable, let config = try? Config.load(from: ctx.project.configURL) {
            let skill = await skillAvailable(config, ctx, approved.goal.base)
            for warning in ProofCommands.warnings(goal: approved.goal, config: config, verifierSkillAvailable: skill) {
                out("warning: " + warning.line)
            }
        }
        if before?.goal.approval != .approved { out("next:    workbench run   (doctor first: workbench doctor)") }
    }

    static func run(_ args: [String]) async throws -> Int32 {
        var a = Arguments(args)
        let feedback = try a.value("--feedback", "-f")
        // Accepted and ignored: a checkout with local edits no longer blocks a run.
        let allowDirty = a.flag("--allow-dirty")
        let allowUnrunnable = a.flag("--allow-unrunnable-proofs")
        let noPlan = a.flag("--no-plan")
        let named = a.positional()
        try a.requireEmpty()

        let ctx = try await Context.load()
        let id = try ctx.threadID(named)
        var options = RunOptions(feedback: feedback)
        options.noPlan = noPlan
        options.allowDirty = allowDirty
        options.allowUnrunnableProofs = allowUnrunnable
        return try await runTurn(ctx: ctx, id: id, options: options)
    }

    /// `send-back "<note>" [--budget <usd>] [id]`: the next turn with the note and the failed check's output.
    static func sendBack(_ args: [String]) async throws -> Int32 {
        var a = Arguments(args)
        let budgetText = try a.value("--budget")
        let allowUnrunnable = a.flag("--allow-unrunnable-proofs")
        let note = a.positional()
        let named = a.positional()
        try a.requireEmpty()
        guard let note, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CLIError.usage("send-back needs a note: workbench send-back \"<what to change>\" [--budget <usd>]")
        }
        var budget: Decimal?
        if let budgetText {
            // Decimal(string:) accepts a numeric prefix ("12.5oops"), so the whole text is checked first.
            guard budgetText.range(of: #"^[0-9]+(\.[0-9]+)?$"#, options: .regularExpression) != nil,
                let value = Decimal(string: budgetText, locale: Locale(identifier: "en_US_POSIX")), value > 0
            else {
                throw CLIError.usage("--budget needs a positive number of dollars, got '\(budgetText)'")
            }
            budget = value
        }
        let ctx = try await Context.load()
        let id = try ctx.threadID(named)
        var options = RunOptions(feedback: note)
        options.budgetOverride = budget
        options.allowUnrunnableProofs = allowUnrunnable
        return try await runTurn(ctx: ctx, id: id, options: options)
    }

    static func runTurn(ctx: Context, id: String, options: RunOptions) async throws -> Int32 {

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
                if report.permissionDenials > 0 {
                    out("  `workbench grant` lists what was denied and lets you allow it; then send the work back")
                }
            case .advisory(let text):
                out("note: \(text)")
            case .setupStarted(let command):
                out("setup started: \(command)")
            case .setupRan(let setup):
                out("setup \(setup.result.rawValue)  \(setup.durationMs / 1000)s"
                    + "  (\(ctx.project.threadDirectory(id).appendingPathComponent(setup.outputRef).path))")
            case .verifierStarted, .verifierEnded:
                printVerifierNotice(notice)
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

        let report = try await runner.run(options)
        if let summary = report.summary, report.result == .succeeded {
            out()
            out(summary)
        }
        out()
        out("review:  workbench log    (worktree: \(ctx.project.worktreesDirectory.appendingPathComponent(id).path))")
        switch report.result {
        case .succeeded: return 0
        case .failed, .interrupted:
            return fail(.failed, "turn \(report.turn) ended \(report.result.rawValue). `workbench log` has the details.")
        case .stopped: return fail(.stopped, "turn \(report.turn) was stopped.")
        case .timedOut: return fail(.timedOut, "turn \(report.turn) timed out.")
        case .budgetExceeded: return fail(.budgetExceeded, "turn \(report.turn) went over its budget.")
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

    static func abandon(_ args: [String]) async throws {
        var a = Arguments(args)
        let force = a.flag("--force")
        let named = a.positional()
        try a.requireEmpty()
        let ctx = try await Context.load()
        let id = try ctx.threadID(named)
        let saved = try await ctx.service.abandon(id: id, force: force)
        out("abandoned \(id); its branch workbench/\(id) is kept")
        if let saved {
            let kib = max(1, saved.bytes >> 10)
            out("uncommitted changes saved to \(saved.url.path) (\(kib) KiB)")
            out("restore them with `git apply` in a checkout of workbench/\(id) at \(saved.head.prefix(12))")
        }
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
    installStopHandlers(what: "the turn") { await runner.stop() }
}

func installStopHandlers(what: String, stop: @escaping @Sendable () async -> Void) -> [DispatchSourceSignal] {
    var sources: [DispatchSourceSignal] = []
    for sig in [SIGINT, SIGTERM] {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler {
            err("\nstopping: ending \(what) cleanly (press Ctrl-C again to quit immediately)")
            Task { await stop() }
            signal(sig, SIG_DFL)  // a second press takes the default action
        }
        source.resume()
        sources.append(source)
    }
    return sources
}
