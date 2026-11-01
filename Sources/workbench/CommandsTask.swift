import Foundation
import WorkbenchCore

extension Commands {
    private static let taskUsage =
        "usage: workbench task list | task log <name> | task new <name> | task approve <name> | task run <name> | task tick"
        + " | task timer install|status|remove"

    /// `task list` shows the project's scheduled tasks; `task approve <name>` lets one run unattended; `task run <name>` runs
    /// one now; `task tick` runs the ones that are due, one after the other.
    static func task(_ args: [String]) async throws -> Int32 {
        var a = Arguments(args)
        guard let verb = a.positional() else { throw CLIError.usage(taskUsage) }
        switch verb {
        case "list":
            try a.requireEmpty()
            try await taskList()
        case "new":
            let include = try a.value("--include")
            var inputs: [String] = []
            while let input = try a.value("--input") { inputs.append(input) }
            guard let name = a.positional() else {
                throw CLIError.usage("usage: workbench task new <name> [--include <file>] [--input <path>]...")
            }
            try a.requireEmpty()
            try await taskNew(name, include: include, inputs: inputs)
        case "log":
            let all = a.flag("--all")
            guard let name = a.positional() else { throw CLIError.usage("usage: workbench task log <name> [--all]") }
            try a.requireEmpty()
            try await taskLog(name, all: all)
        case "approve":
            guard let name = a.positional() else { throw CLIError.usage("usage: workbench task approve <name>") }
            try a.requireEmpty()
            try await taskApprove(name)
        case "run":
            let dry = a.flag("--dry")
            guard let name = a.positional() else { throw CLIError.usage("usage: workbench task run <name> [--dry]") }
            try a.requireEmpty()
            return try await taskRun(name, dry: dry)
        case "tick":
            let all = a.flag("--all")
            try a.requireEmpty()
            if all { return try await taskTickAll() }
            let stopped = StopFlag()
            let signals = installStopHandlers(what: "the run") { await stopped.raise() }
            defer { signals.forEach { $0.cancel() } }
            return try await taskTick(Context.load(), stopped: stopped)
        case "timer":
            return try await taskTimer(&a)
        default:
            throw CLIError.usage("unknown task command '\(verb)'. \(taskUsage)")
        }
        return 0
    }

    private static func taskRunner(_ ctx: Context) -> TaskRunner {
        var runner = TaskRunner(project: ctx.project, git: ctx.git, gh: try? GitRunner.discover(tool: "gh"))
        runner.notice = { out("  \($0)") }
        return runner
    }

    /// Says how a run ended and returns the exit code for it: 0 when it did its work or found none, 6 when it was
    /// refused or skipped (nothing was changed), 5 over budget, 1 when it failed.
    private static func report(_ name: String, _ result: TaskRunResult) -> Int32 {
        out("\(name): \(result.outcome.rawValue)" + (result.reason.map { "  \($0)" } ?? ""))
        if !result.units.isEmpty { out("  units:  \(result.units.joined(separator: ", "))") }
        if let thread = result.thread { out("  thread: \(thread)") }
        if let url = result.pullRequest { out("  pull request: \(url)") }
        if !result.recorded { out("  not recorded in the task's run log") }
        switch result.outcome {
        case .prOpened, .reported, .nothingPending, .nothingToDo: return 0
        case .skippedProjectBusy, .skippedAlreadyRunning, .skippedTooManyOpen, .staleApproval: return 6
        case .budgetExceeded: return 5
        case .failed, .interrupted: return 1
        }
    }

    private static func taskRun(_ name: String, dry: Bool) async throws -> Int32 {
        let ctx = try await Context.load()
        guard TaskLibrary(project: ctx.project).names().contains(name) else {
            throw CLIError.notFound("no task '\(name)' (.workbench/tasks/\(name)/task.md)")
        }
        var runner = taskRunner(ctx)
        runner.dryRun = dry
        let signals = installStopHandlers(what: "the run") { [runner] in await runner.stop.stop() }
        defer { signals.forEach { $0.cancel() } }
        return report(name, await runner.run(name, trigger: .manual))
    }

    /// Set by the first Ctrl-C or SIGTERM: the project being ticked ends its run cleanly and no later project starts.
    final class StopFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var set = false
        private var current: TaskStopSwitch?
        var isSet: Bool { lock.withLock { set } }
        func use(_ stop: TaskStopSwitch) { lock.withLock { current = stop } }
        func raise() async {
            let stop = lock.withLock { () -> TaskStopSwitch? in
                set = true
                return current
            }
            await stop?.stop()
        }
    }

    private static func taskTick(_ ctx: Context, stopped: StopFlag) async throws -> Int32 {
        let plan = TaskTick.plan(project: ctx.project)
        // A task that cannot be loaded is said out loud and fails the tick: a timer that hears nothing assumes all is well.
        for broken in plan.broken {
            out("\(broken.name): PROBLEM  \(broken.reason.split(whereSeparator: \.isNewline).joined(separator: "; "))")
        }
        let names = plan.due
        guard !names.isEmpty else {
            if plan.broken.isEmpty { out("no task is due") }
            return plan.broken.isEmpty ? 0 : 1
        }
        let runner = taskRunner(ctx)
        stopped.use(runner.stop)
        var code: Int32 = plan.broken.isEmpty ? 0 : 1
        for name in names {
            if stopped.isSet { break }
            // One after the other: a project has one active thread.
            let result = await runner.run(name, trigger: .tick)
            _ = report(name, result)
            // A timer cares about runs that went wrong. A skip is a note, not a failure: the next tick tries again.
            if [.failed, .budgetExceeded, .interrupted].contains(result.outcome) { code = 1 }
        }
        return code
    }

    /// `task tick --all`: the tick of every project that has a timer installed (their agents' folders), one after the other. A folder
    /// that is gone or is no longer a repository is said out loud and fails the pass, like a task that cannot be loaded: a timer that
    /// hears nothing assumes all is well.
    private static func taskTickAll() async throws -> Int32 {
        let home = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory(), isDirectory: true)
        let entries = TimerRegistry.projects(home: home)
        guard !entries.isEmpty else {
            out("no project has a timer installed (workbench task timer install, in the project)")
            return 0
        }
        // One set of handlers for the whole pass, so a Ctrl-C between two projects is not lost.
        let stopped = StopFlag()
        let signals = installStopHandlers(what: "the run") { await stopped.raise() }
        defer { signals.forEach { $0.cancel() } }
        var code: Int32 = 0
        for entry in entries {
            if stopped.isSet { break }
            out("== \(entry.root.lastPathComponent)  (\(entry.root.path))")
            let loaded = FileManager.default.fileExists(atPath: entry.root.path) ? try? await Context.load(at: entry.root) : nil
            guard let ctx = loaded, entry.isTheProject(ctx.project) else {
                out("PROBLEM  \(entry.root.path) is gone or is not a repository: workbench task timer remove, in that project")
                code = 1
                continue
            }
            if (try await taskTick(ctx, stopped: stopped)) != 0 { code = 1 }
        }
        return code
    }

    private static func taskList() async throws {
        let ctx = try await Context.load()
        let library = TaskLibrary(project: ctx.project)
        let names = library.names()
        guard !names.isEmpty else {
            out("no tasks (a task is .workbench/tasks/<name>/task.md)")
            return
        }
        let format = DateFormatter()
        format.dateFormat = "yyyy-MM-dd HH:mm"
        for name in names {
            let summary = library.summary(name)
            if let problem = summary.problem {
                out("\(name)  PROBLEM  \(problem.split(whereSeparator: \.isNewline).joined(separator: "; "))")
                printWhy(summary)
                continue
            }
            let approval: String
            switch summary.approval {
            case .approved: approval = "approved"
            case .stale: approval = "STALE (changed since approved: run task approve)"
            case .never: approval = "not approved"
            }
            let due = summary.nextDue.map { format.string(from: $0) } ?? (summary.schedule == nil ? "manual" : "after approval")
            let last =
                summary.lastRun.map { "\(summary.lastOutcome?.rawValue ?? "running") \(format.string(from: $0))" } ?? "never run"
            out(
                "\(name)  \(summary.schedule ?? "no schedule")  fix: \(summary.fix?.rawValue ?? "-")  \(approval)  "
                    + "next: \(due)  last: \(last)")
            printWhy(summary)
        }
    }

    /// Why the last run did not end well, so it need not be dug out of a thread. Also for a task that cannot be loaded now.
    private static func printWhy(_ summary: TaskSummary) {
        let fine: Set<TaskOutcome> = [.prOpened, .reported, .nothingPending]
        if let outcome = summary.lastOutcome, !fine.contains(outcome), let reason = summary.lastReason {
            out("    why: " + TaskExplanation.clean(reason, limit: 240))
        }
    }

    private static func taskLog(_ name: String, all: Bool) async throws {
        let ctx = try await Context.load()
        guard TaskLibrary(project: ctx.project).names().contains(name) else {
            throw CLIError.notFound("no task '\(name)' (.workbench/tasks/\(name)/task.md)")
        }
        do {
            for line in try TaskLogReport.lines(project: ctx.project, name: name, all: all) { out(line) }
        } catch let error as EventLogError {
            throw CLIError.refused("the task's run log is damaged: \(error)")
        }
    }

    private static func taskNew(_ name: String, include: String?, inputs: [String]) async throws {
        let ctx = try await Context.load()
        let result: TaskScaffoldResult
        do {
            result = try TaskScaffold.create(project: ctx.project, name: name, include: include, inputs: inputs)
        } catch let error as TaskScaffoldError {
            switch error {
            case .exists, .outsideProject: throw CLIError.refused("\(error)")
            default: throw CLIError.usage("\(error)")
            }
        }
        out("created .workbench/tasks/\(name)/")
        out("  task.md     every setting, explained; fix: report until you change it")
        out("  pending.sh  prints the units of work; it lists none yet")
        for path in result.missing { out("note: \(path) does not exist yet; create it before the task runs") }
        if !FileManager.default.fileExists(atPath: ctx.project.configURL.path) {
            out("note: no .workbench/config.toml yet; run `workbench init` (fix: pr needs check_command in it)")
        }
        // Tasks are local: a `.workbench/` that git would commit puts them in the repository. Every file the task will hold is
        // asked about, not only task.md: a rule such as `*.md` ignores that one and leaves the script and the run log.
        var exposed: [String] = []
        for file in ["task.md", "pending.sh", "runs.jsonl"] {
            let ignored = try? await ctx.git.run(
                ["check-ignore", "-q", ".workbench/tasks/\(name)/\(file)"], in: ctx.project.root)
            if let ignored, ignored.status == 1 { exposed.append(file) }
        }
        if !exposed.isEmpty {
            out(
                "note: git does not ignore \(exposed.joined(separator: ", ")) here; add .workbench/ to .gitignore or "
                    + ".git/info/exclude, since tasks are local")
        }
        out("then:    edit .workbench/tasks/\(name)/task.md and pending.sh")
        out("         workbench task run \(name)       (lists what it would take while fix: report)")
        out("         workbench task approve \(name)")
    }

    private static func taskApprove(_ name: String) async throws {
        let ctx = try await Context.load()
        let library = TaskLibrary(project: ctx.project)
        guard library.names().contains(name) else {
            throw CLIError.notFound("no task '\(name)' (.workbench/tasks/\(name)/task.md)")
        }
        let loaded: LoadedTask
        do { loaded = try library.load(name) } catch {
            throw CLIError.refused("the task cannot be approved: \(error)")
        }
        let hash: String
        do { hash = try await library.approve(name) } catch let error as EventLogError {
            throw CLIError.refused("the task's run log is in use or damaged: \(error)")
        } catch let error as TaskFileError {
            throw CLIError.refused("the task cannot be approved: \(error)")
        }
        out("approved \(name) (\(hash.prefix(12)))")
        if let schedule = loaded.definition.schedule { out("it is due \(schedule.summary)") }
        // A schedule nobody ticks does nothing: say how to make the machine do it.
        if let schedule = loaded.definition.schedule, let service = try? await timerService(),
            !FileManager.default.fileExists(atPath: service.paths.plist.path) {
            out("hint: it runs \(schedule.summary), but no timer is installed: workbench task timer install")
        }
        if loaded.definition.fix == .pr {
            out(
                "fix: pr: when its check and verifier pass, the task accepts its own work and opens the pull request. "
                    + "It never merges.")
        }
    }
}
