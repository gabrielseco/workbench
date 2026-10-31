import Foundation
import WorkbenchCore

extension Commands {
    /// `task list` shows the project's scheduled tasks; `task approve <name>` lets one run unattended.
    static func task(_ args: [String]) async throws {
        var a = Arguments(args)
        guard let verb = a.positional() else {
            throw CLIError.usage("usage: workbench task list | task approve <name>")
        }
        switch verb {
        case "list":
            try a.requireEmpty()
            try await taskList()
        case "approve":
            guard let name = a.positional() else { throw CLIError.usage("usage: workbench task approve <name>") }
            try a.requireEmpty()
            try await taskApprove(name)
        default:
            throw CLIError.usage("unknown task command '\(verb)'. usage: workbench task list | task approve <name>")
        }
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
        }
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
        }
        out("approved \(name) (\(hash.prefix(12)))")
        if let schedule = loaded.definition.schedule { out("it is due \(schedule.summary)") }
        if loaded.definition.fix == .pr {
            out(
                "fix: pr: when its check and verifier pass, the task accepts its own work and opens the pull request. "
                    + "It never merges.")
        }
    }
}
