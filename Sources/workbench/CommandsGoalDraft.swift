import Foundation
import WorkbenchCore

extension Commands {
    /// `goal draft <name> --request "<text>" | --request-file <path> [--base <branch>] [--replace]`: the goal agent drafts
    /// a goal from a rough request. Read-only; it approves nothing and runs nothing. A draft that does not produce a valid
    /// goal writes nothing.
    static func goalDraft(_ args: [String]) async throws -> Int32 {
        var a = Arguments(args)
        let text = try a.value("--request")
        let path = try a.value("--request-file")
        let base = try a.value("--base")
        let replace = a.flag("--replace")
        let named = a.positional()
        try a.requireEmpty()
        let usage =
            "usage: workbench goal draft <name> (--request \"<text>\" | --request-file <path>) [--base <branch>] [--replace]"
        guard (text == nil) != (path == nil) else {
            throw CLIError.usage("give the rough request once, as --request or --request-file. " + usage)
        }
        if replace && base != nil { throw CLIError.usage("--replace keeps the goal's base: drop --base") }
        if !replace && named == nil { throw CLIError.usage(usage) }
        let request: String
        if let text { request = text } else if let path { request = try readRequestFile(path) } else { request = "" }

        let ctx = try await Context.load()
        // A config that is there but broken is its error (with the offending key), not "no goal agent".
        let config: Config? =
            FileManager.default.fileExists(atPath: ctx.project.configURL.path)
            ? try Config.load(from: ctx.project.configURL) : nil
        let target: GoalDraftTarget
        if replace {
            target = .replace(id: try ctx.threadID(named))
        } else if let named {
            target = .newThread(name: named, base: base)
        } else {
            throw CLIError.usage(usage)
        }
        if let agent = config?.resolvedGoalAgent {
            let capped = config?.agentProvider(agent.provider)?.capabilities.hardDollarCap ?? true
            out(
                "drafting on \(agent.provider)\(agent.model.map { ", \($0)" } ?? "") (read-only; "
                    + (capped
                        ? "up to $\(NSDecimalNumber(decimal: GoalDraft.budgetUSD).stringValue)"
                        : "no dollar cap: bounded by \(Int(GoalDraft.timeout / 60)) min") + ")...")
        }
        // Ctrl-C stops the drafter instead of leaving it running on its own budget.
        let holder = RunHolder()
        let signals = installStopHandlers(what: "the draft") { holder.stop() }
        defer { signals.forEach { $0.cancel() } }
        let result: GoalDraftResult
        do {
            result = try await ctx.service.draftGoal(
                target: target, request: request, config: config, attach: { holder.attach($0) })
        } catch let error as GoalDraftRefusal {
            throw CLIError.refused("\(error)")
        }
        let cost = result.costUSD.map { String(format: "$%.4f", $0) } ?? "cost unknown"
        guard let id = result.id, let proposal = result.proposal else {
            let why = result.failure ?? "no proposal"
            return fail(holder.isStopRequested ? .stopped : .failed, "no draft (\(cost)): \(why). Nothing was written.")
        }
        let verb = result.replaced ? "redrafted" : "drafted"
        out("\(verb) \(id)   (\(result.provider), \(result.model ?? "default model"); \(cost))")
        out("title:   \(proposal.title)")
        out("criteria: \(proposal.body.criteria.count)")
        if result.wasApproved { out("the goal was approved: it is a draft again and needs `workbench goal approve`") }
        out("edit:    \(ctx.project.goalURL(id).path)")
        out("then:    read it, edit what is wrong, workbench goal approve")
        return 0
    }

    /// The rough request from a file: a regular file of at most `GoalDraft.requestLimit` bytes.
    private static func readRequestFile(_ path: String) throws -> String {
        let fd = Darwin.open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw CLIError.usage("no request file at \(path)") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw CLIError.usage("\(path) is not a regular file")
        }
        guard info.st_size <= GoalDraft.requestLimit else {
            throw CLIError.usage("\(path) is over \(GoalDraft.requestLimit / 1024) KiB; shorten the request")
        }
        let data = FileHandle(fileDescriptor: fd, closeOnDealloc: false).readData(ofLength: GoalDraft.requestLimit + 1)
        return String(decoding: data, as: UTF8.self)
    }
}
