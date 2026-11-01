import Foundation
import WorkbenchCore

/// What a person sees before a task may run with nobody watching: the settings, the instructions, and the files the approval binds to.
struct TaskCardInfo: Equatable {
    struct Line: Equatable {
        var label: String
        var value: String
    }
    var name: String
    /// What approval binds to for this version of the task: approving or running confirms only this one.
    var hash: String
    var settings: [Line]
    var instructions: String
    var fix: TaskFix
    /// What a `fix: pr` run may cost, in words: the coding turns' cap and the allowance for describing the change.
    var cost: String

    static func make(_ loaded: LoadedTask, name: String) -> TaskCardInfo {
        let task = loaded.definition
        var lines = [
            Line(label: "when", value: task.schedule?.summary ?? "by hand only"),
            Line(
                label: "fix",
                value: task.fix == .pr ? "pr: does the work, opens a pull request, merges nothing" : "report: a dry run"),
            Line(label: "batch", value: "\(task.batch) unit\(task.batch == 1 ? "" : "s") a run"),
            Line(label: "budget", value: task.budgetUSD.map { "$\(money($0)) a run" } ?? "none set"),
        ]
        if let maxOpen = task.maxOpen { lines.append(Line(label: "max_open", value: "\(maxOpen)")) }
        if let timeout = task.timeoutMin { lines.append(Line(label: "timeout", value: "\(timeout) min a turn")) }
        if let base = task.base { lines.append(Line(label: "base", value: base)) }
        if let pending = task.pending {
            let size = loaded.pendingScript?.count ?? 0
            lines.append(Line(label: "pending", value: "\(pending) (\(size) bytes, run with no one watching)"))
        }
        if let include = task.include {
            let size = loaded.includeText?.count ?? 0
            lines.append(Line(label: "skill", value: "\(include) (\(size) bytes, followed by the agent)"))
        }
        if !task.inputs.isEmpty { lines.append(Line(label: "inputs", value: task.inputs.joined(separator: ", "))) }
        return TaskCardInfo(
            name: name, hash: loaded.hash, settings: lines, instructions: task.instructions, fix: task.fix, cost: cost(task))
    }

    /// The most a `fix: pr` run may spend: the coding turns' budget and the read-only turn that describes the change.
    static func cost(_ task: TaskDefinition) -> String {
        guard let budget = task.budgetUSD else { return "unknown: the task sets no budget" }
        let describing = PRDescriber.budgetUSD
        let most = money(budget + describing)
        return "up to $\(money(budget)) for the work and $\(money(describing)) to describe it: at most $\(most)"
    }

    static func money(_ value: Decimal) -> String {
        String(format: "%.2f", NSDecimalNumber(decimal: value).doubleValue)
    }
}

/// What the Tasks screen's two buttons do, as core does it. A seam so a test can see the order and the refusals without Claude, git or gh.
struct TaskActions: Sendable {
    /// What approval would bind to, read from disk now. Throws the core's message for a task that does not load.
    var inspect: @Sendable (Project, String) throws -> TaskCardInfo
    /// `TaskLibrary.approve` for the version shown (its hash): records the approval, or throws the core's refusal.
    var approve: @Sendable (Project, String, String) async throws -> Void
    /// `TaskRunner.run(name, trigger: .manual)`. The stop switch ends the turn; `notice` is what the run says as it goes.
    var run: @Sendable (Project, String, TaskStopSwitch, @escaping @Sendable (String) -> Void) async -> TaskRunResult

    static let core = TaskActions(
        inspect: { project, name in TaskCardInfo.make(try TaskLibrary(project: project).load(name), name: name) },
        approve: { project, name, hash in
            do {
                try await TaskLibrary(project: project).approve(name, expecting: hash)
            } catch { throw GoalActions.RefusalText("\(error)") }
        },
        run: { project, name, stop, notice in
            guard let git = try? GitRunner.discover() else {
                return TaskRunResult(outcome: .failed, reason: "git was not found", recorded: false)
            }
            var runner = TaskRunner(project: project, git: git, gh: GoalActions.pullRequestGH())
            runner.stop = stop
            runner.notice = notice
            return await runner.run(name, trigger: .manual)
        })
}
