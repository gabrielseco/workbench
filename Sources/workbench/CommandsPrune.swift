import Foundation
import WorkbenchCore

extension Commands {
    /// `prune [--yes] [--closed] [--unregistered]`: list every git worktree of the repository, say which can be
    /// removed and why the rest are kept; with `--yes`, remove the removable ones and their local branches. A dry
    /// run unless `--yes`. Asks GitHub about branches not already on the default branch.
    static func prune(_ args: [String]) async throws -> Int32 {
        var a = Arguments(args)
        let yes = a.flag("--yes", "-y")
        let closed = a.flag("--closed")
        let unregistered = a.flag("--unregistered")
        try a.requireEmpty()
        let ctx = try await Context.load()
        let gh = try? GitRunner.discover(tool: "gh")

        let report: PruneReport
        do {
            report = try await ctx.service.prune(gh: gh, includeClosed: closed, unregistered: unregistered, dryRun: !yes)
        } catch let error as PruneError {
            return fail(.failed, error.description)
        }
        for line in report.render() { out(line) }
        if !yes {
            out("dry run: nothing was changed. `workbench prune --yes` removes what is marked removable.")
        }
        if report.lookupFailed {
            return fail(.failed, "GitHub could not be asked about some worktrees; they were kept.")
        }
        if report.removalFailed { return fail(.failed, "some worktrees could not be removed; they are listed above.") }
        return 0
    }
}
