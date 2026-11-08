import Foundation
import WorkbenchCore

extension Commands {
    /// `sync [id]`: the base's new commits come into the thread's branch, in its worktree. Exit 0 when it merged or there was nothing
    /// to bring in, 1 when the merge stopped on conflicts (left in progress), 6 when it could not start (nothing was changed).
    static func sync(_ args: [String]) async throws -> Int32 {
        var a = Arguments(args)
        let named = try a.thread()
        try a.requireEmpty()
        let ctx = try await Context.load()
        let id = try ctx.threadID(named)
        out("bringing the base into \(id)...")
        switch try await ctx.service.syncBase(id: id) {
        case .upToDate(let moved):
            out("\(moved.base) has not moved since this thread started; nothing to bring in")
            return 0
        case .merged(let moved, let head, let saved):
            if let saved { out("saved the thread's uncommitted work as \(saved), so the merge starts clean") }
            out("merged origin/\(moved.base) (\(moved.behind) commit\(moved.behind == 1 ? "" : "s")) at \(head)")
            out(moved.line)
            out("the check has not run on the result yet: `workbench send-back \"origin/\(moved.base) was merged in; make sure it still passes\"` runs it")
            return 0
        case .conflicts(let moved, let files, let saved):
            if let saved { out("saved the thread's uncommitted work as \(saved), so the merge starts clean") }
            out("merging origin/\(moved.base) stopped on \(files.count) file(s) with conflicts:")
            for file in files.prefix(20) { out("  \(file)") }
            if files.count > 20 { out("  ... and \(files.count - 20) more") }
            let path = WorktreeManager(repoRoot: ctx.project.root, git: ctx.git).path(for: id).path
            out("the merge is left in progress in \(path): resolve the files there, or ask for it with")
            out("  workbench send-back \"resolve the merge conflicts from bringing in \(moved.base), keeping both sides' intent\"")
            return fail(.failed, "the merge stopped on conflicts")
        }
    }
}
