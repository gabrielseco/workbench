import Foundation
import WorkbenchCore

extension Commands {
    /// `sync [id]`: the base's new commits come into the thread's branch, in its worktree. Exit 0 when it merged or there was nothing
    /// to bring in, 1 when the merge stopped on conflicts (left in progress), 6 when it could not start (nothing was changed). With
    /// `--run` the exit code is the turn's, as for `send-back`: a turn that resolves the conflicts and passes the check is 0.
    static func sync(_ args: [String]) async throws -> Int32 {
        var a = Arguments(args)
        let runTurnAfter = a.flag("--run")
        let budgetText = try a.value("--budget")
        let named = try a.thread()
        try a.requireEmpty()
        if budgetText != nil, !runTurnAfter { throw CLIError.usage("--budget is for the turn `--run` starts") }
        var budget: Decimal?
        if let budgetText {
            guard budgetText.range(of: #"^[0-9]+(\.[0-9]+)?$"#, options: .regularExpression) != nil,
                let value = Decimal(string: budgetText, locale: Locale(identifier: "en_US_POSIX")), value > 0
            else { throw CLIError.usage("--budget needs a positive number of dollars, got '\(budgetText)'") }
            budget = value
        }
        let ctx = try await Context.load()
        let id = try ctx.threadID(named)
        // Before anything is merged: a turn that is refused afterwards would leave the merge done and the person guessing.
        if runTurnAfter, ctx.store.state(of: id).lastTurn == 0 {
            throw CLIError.refused("this thread has had no turn yet: use `workbench sync` alone")
        }
        out("bringing the base into \(id)...")
        let result = try await ctx.service.syncBase(id: id)
        switch result {
        case .upToDate(let moved):
            out("\(moved.base) has not moved since this thread started; nothing to bring in")
            return 0
        case .merged(let moved, let head, let saved):
            if let saved { out("saved the thread's uncommitted work as \(saved), so the merge starts clean") }
            out("merged origin/\(moved.base) (\(moved.behind) commit\(moved.behind == 1 ? "" : "s")) at \(head)")
            out(moved.line)
            if runTurnAfter { return try await turnAfterSync(result, ctx: ctx, id: id, budget: budget) }
            out("the check has not run on the result yet; this runs it:")
            out("  workbench send-back --thread \(id) \"origin/\(moved.base) was merged in; make sure it still passes\"")
            return 0
        case .failed:
            return fail(.failed, "git could not merge the base")  // syncBase throws instead; here for completeness
        case .conflicts(let moved, let files, let saved):
            if let saved { out("saved the thread's uncommitted work as \(saved), so the merge starts clean") }
            out("merging origin/\(moved.base) stopped on \(files.count) file(s) with conflicts:")
            for file in files.prefix(20) { out("  \(file)") }
            if files.count > 20 { out("  ... and \(files.count - 20) more") }
            if runTurnAfter { return try await turnAfterSync(result, ctx: ctx, id: id, budget: budget) }
            let path = WorktreeManager(repoRoot: ctx.project.root, git: ctx.git).path(for: id).path
            out("the merge is left in progress in \(path): resolve the files there, or ask for it with")
            out("  workbench send-back --thread \(id) \"resolve the merge conflicts from bringing in \(moved.base)\"")
            return fail(.failed, "the merge stopped on conflicts")
        }
    }

    /// The turn `sync --run` starts: the same as `send-back`, with the note Workbench wrote about what the sync did.
    private static func turnAfterSync(
        _ result: BaseSyncResult, ctx: Context, id: String, budget: Decimal?
    ) async throws -> Int32 {
        guard let note = SyncPrompt.note(for: result) else { return 0 }
        out("starting a turn to bring the work up to date with the new base...")
        var options = RunOptions(feedback: note)
        options.budgetOverride = budget
        return try await runTurn(ctx: ctx, id: id, options: options)
    }
}
