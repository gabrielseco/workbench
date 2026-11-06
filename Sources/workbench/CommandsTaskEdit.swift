import Foundation
import WorkbenchCore

extension Commands {
    static let taskEditUsage =
        "usage: workbench task edit <name> (\"<request>\" | --request \"<text>\" | --request-file <path>) [--accept]"

    /// `task edit <name> --request "<text>"`: the goal agent proposes a new task.md, which is checked as the loader would and shown as
    /// what it changes. Nothing is written unless `--accept`, and accepting never approves: an approved task reads stale.
    static func taskEdit(_ a: inout Arguments) async throws -> Int32 {
        let text = try a.value("--request")
        let path = try a.value("--request-file")
        let accept = a.flag("--accept")
        guard let name = a.positional() else { throw CLIError.usage(taskEditUsage) }
        let words = a.positional()
        try a.requireEmpty()
        guard [text, path, words].compactMap({ $0 }).count == 1 else {
            throw CLIError.usage("give the request once, as words, --request or --request-file. " + taskEditUsage)
        }
        let request = try text ?? words ?? readRequestFile(path ?? "")
        let ctx = try await Context.load()
        let config: Config? =
            FileManager.default.fileExists(atPath: ctx.project.configURL.path)
            ? try Config.load(from: ctx.project.configURL) : nil
        if let agent = config?.resolvedGoalAgent, let limit = TaskEdit.limit(config: config) {
            out("editing on \(agent.provider)\(agent.model.map { ", \($0)" } ?? "") (read-only; \(limit))...")
        }
        // Ctrl-C stops the agent instead of leaving it running on its own budget.
        let holder = RunHolder()
        let signals = installStopHandlers(what: "the edit") { holder.stop() }
        defer { signals.forEach { $0.cancel() } }
        let editor = TaskEditor(project: ctx.project)
        let result: TaskEditResult
        do {
            result = try await editor.propose(task: name, request: request, config: config, attach: { holder.attach($0) })
        } catch let error as TaskEditRefusal {
            throw CLIError.refused("\(error)")
        }
        let cost = result.costUSD.map { String(format: "$%.4f", $0) } ?? "cost unknown"
        guard let proposal = result.proposal else {
            let why = result.failure ?? "no proposal"
            return fail(holder.isStopRequested ? .stopped : .failed, "no edit (\(cost)): \(why). Nothing was written.")
        }
        out("proposed \(name)   (\(result.provider), \(result.model ?? "default model"); \(cost))")
        printChanges(proposal.changes)
        guard !proposal.changes.isEmpty else {
            out("the agent changed nothing. Nothing was written.")
            return 0
        }
        guard accept else {
            out("nothing was written. To write it: run again with --accept (the agent is asked again), or edit the file by hand.")
            return 0
        }
        do { try editor.accept(proposal) } catch let error as TaskEditRefusal {
            throw CLIError.refused("\(error)")
        }
        out("wrote \(ctx.project.taskFileURL(name).path)")
        out("then:    read it, workbench task approve \(name)   (an approval it had no longer holds)")
        return 0
    }

    private static func printChanges(_ changes: TaskChanges) {
        if !changes.settings.isEmpty {
            out("settings (each one is part of what approval binds to):")
            for change in changes.settings {
                out("  \(change.key): \(change.old ?? "(not set)") -> \(change.new ?? "(not set)")")
            }
        }
        guard changes.instructionsChanged else { return }
        out("instructions:")
        for line in changes.instructions {
            let mark = line.kind == .added ? "+" : line.kind == .removed ? "-" : " "
            out("  \(mark) \(line.text)")
        }
    }
}
