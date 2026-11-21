import Foundation
import WorkbenchCore

extension Commands {
    private static let seriesUsage = "usage: workbench series list | series show <name> | series status <name>"
        + " | series approve <name> | series run <name>"

    /// `series list` shows the project's series; `series show <name>` its steps; `series approve <name>` binds the file and its
    /// goal files (P27). Nothing here starts a step.
    static func series(_ args: [String]) async throws -> Int32 {
        var a = Arguments(args)
        guard let verb = a.positional() else { throw CLIError.usage(seriesUsage) }
        switch verb {
        case "list":
            try a.requireEmpty()
            try await seriesList()
        case "run":
            guard let name = a.positional() else { throw CLIError.usage("usage: workbench series run <name>") }
            try a.requireEmpty()
            return try await seriesRun(name)
        case "status":
            guard let name = a.positional() else { throw CLIError.usage("usage: workbench series status <name>") }
            try a.requireEmpty()
            try await seriesStatus(name)
        case "show", "approve":
            guard let name = a.positional() else { throw CLIError.usage("usage: workbench series \(verb) <name>") }
            try a.requireEmpty()
            try await seriesShow(name, approve: verb == "approve")
        default:
            throw CLIError.usage("unknown series command '\(verb)'. \(seriesUsage)")
        }
        return 0
    }

    private static func seriesLoad(_ library: SeriesLibrary, _ name: String) throws -> LoadedSeries {
        guard library.names().contains(name) else {
            throw CLIError.notFound("no series '\(name)' (.workbench/series/\(name)/series.md)")
        }
        do { return try library.load(name) } catch let error as SeriesError {
            throw CLIError.refused("the series is not valid:\n\(error)")
        }
    }

    private static func approvalWord(_ state: SeriesApproval.State) -> String {
        switch state {
        case .approved: "approved"
        case .stale: "STALE (changed since approved: run series approve)"
        case .never: "not approved"
        }
    }

    private static func seriesList() async throws {
        let ctx = try await Context.load()
        let library = SeriesLibrary(project: ctx.project)
        let names = library.names()
        guard !names.isEmpty else {
            out("no series (a series is .workbench/series/<name>/series.md)")
            return
        }
        for name in names {
            do {
                let loaded = try library.load(name)
                out("\(name)  \(loaded.definition.steps.count) steps  \(approvalWord(library.state(loaded)))")
            } catch {
                out("\(name)  PROBLEM  \(String(describing: error).split(whereSeparator: \.isNewline).joined(separator: "; "))")
            }
        }
    }

    private static func seriesShow(_ name: String, approve: Bool) async throws {
        let ctx = try await Context.load()
        let library = SeriesLibrary(project: ctx.project)
        let loaded = try seriesLoad(library, name)
        if approve {
            let hash: String
            do { hash = try library.approve(name) } catch let error as SeriesError {
                throw CLIError.refused("\(error)")
            }
            out("approved \(name) (\(hash.prefix(12)))")
        } else {
            out("\(name)  \(approvalWord(library.state(loaded)))")
        }
        if let budget = loaded.definition.budgetUSD {
            out("budget:  \(NSDecimalNumber(decimal: budget)) USD for the whole series")
        }
        for step in loaded.definition.steps {
            let base: String
            switch step.base {
            case .branch(let branch): base = branch ?? "the project's base"
            case .after(let n): base = "the branch of step \(n)"
            }
            let project = loaded.projects[step.number]?.path ?? step.project
            var line = "\(step.number). \(project)  goal \(step.goal)  from \(base)"
            if !step.after.isEmpty { line += "  after \(step.after.map(String.init).joined(separator: ", "))" }
            out(line)
            if let title = loaded.goals[step.number]?.title { out("     \(title)") }
            for pair in step.env {
                switch pair.value {
                case .literal(let value): out("     env \(pair.name)=\(value)")
                case .stepBranch(let n): out("     env \(pair.name)=<branch of step \(n)>")
                }
            }
        }
        if approve { out("nothing started: workbench series run \(name) runs it") }
    }

    private static func seriesStatus(_ name: String) async throws {
        let ctx = try await Context.load()
        let library = SeriesLibrary(project: ctx.project)
        let loaded = try seriesLoad(library, name)
        let states = await library.states(loaded, git: ctx.git, gh: try? GitRunner.discover(tool: "gh"))
        out("\(name)  \(approvalWord(library.state(loaded)))")
        for step in loaded.definition.steps {
            let state = states[step.number] ?? .pending
            let label: String
            switch state {
            case .pending:
                let blocked = SeriesScheduler.blockedBy(step, states: states)
                let names = blocked.map(String.init).joined(separator: ", ")
                label = blocked.isEmpty ? "pending" : "pending, waits for step \(names)"
            case .running(let thread): label = "running  \(thread)"
            case .waiting(let thread, let reason): label = "waiting  \(thread): \(reason)"
            case .clean(let thread, let pr): label = "clean  \(thread)" + (pr.map { "  \($0)" } ?? "")
            case .stopped(let thread, let reason): label = "STOPPED  \(thread): \(reason)"
            }
            out("\(step.number). \(label)")
        }
        if let stopped = SeriesScheduler.stoppedStep(loaded.definition, states: states) {
            out("stopped at step \(stopped.step): nothing new starts until a person fixes it")
        } else if loaded.definition.steps.allSatisfy({ states[$0.number]?.isClean == true }) {
            let urls = loaded.definition.steps.compactMap { step -> String? in
                if case .clean(_, let pr)? = states[step.number] { return pr.map { "\(step.number): \($0)" } }
                return nil
            }
            let list = urls.isEmpty ? "" : "\n  " + urls.joined(separator: "\n  ")
            out("every step is clean: review and merge in this order" + list)
        } else {
            let ready = SeriesScheduler.ready(loaded.definition, states: states)
            let names = ready.map(String.init).joined(separator: ", ")
            out(ready.isEmpty ? "nothing to start now" : "ready to start: step \(names)")
        }
    }

    /// Runs the steps that are ready, one after another, until every step is clean or one stops. Ctrl-C ends the command that is
    /// running (which ends its own turn) and stops the series; nothing is retried and nothing is merged.
    private static func seriesRun(_ name: String) async throws -> Int32 {
        let ctx = try await Context.load()
        let library = SeriesLibrary(project: ctx.project)
        _ = try seriesLoad(library, name)
        let binary = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        let runner = WorkbenchProcessRunner(binary: binary)
        var driver = SeriesDriver(library: library, commands: runner, git: ctx.git, gh: try? GitRunner.discover(tool: "gh"))
        driver.say = { out("  \($0)") }
        let signals = installStopHandlers(what: "the running step") { runner.stop() }
        defer { signals.forEach { $0.cancel() } }
        let result: SeriesRunResult
        do { result = try await driver.run(name) } catch let error as SeriesDriverError {
            throw CLIError.refused("\(error)")
        }
        switch result {
        case .finished:
            out("every step is clean: review and merge in this order")
            let loaded = try seriesLoad(library, name)
            let states = await library.states(loaded, git: ctx.git, gh: try? GitRunner.discover(tool: "gh"))
            for (number, state) in states.sorted(by: { $0.key < $1.key }) {
                if case .clean(_, let pr) = state { out("  \(number): \(pr ?? "(merged)")") }
            }
            return 0
        case .stopped(let step, let reason):
            err("series \(name) stopped at step \(step): \(reason)")
            err("nothing else was started. Fix it with the usual commands (next, send-back, accept, ship);")
            err("`series status` reads it again, and `series run` continues once the step is clean")
            return FailureKind.failed.code
        case .waiting(let step, let reason):
            err("series \(name) waits at step \(step): \(reason)")
            return FailureKind.noResult.code
        }
    }
}
