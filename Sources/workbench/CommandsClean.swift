import Foundation
import WorkbenchCore

extension Commands {
    /// `clean [--yes] [--closed]`: for every shipped thread whose pull request is merged, remove the
    /// worktree and the local branch it left. A dry run unless `--yes`. Asks GitHub; changes only what the
    /// listing says.
    static func clean(_ args: [String]) async throws -> Int32 {
        var a = Arguments(args)
        let yes = a.flag("--yes", "-y")
        let closed = a.flag("--closed")
        try a.requireEmpty()
        let ctx = try await Context.load()
        let gh = try? GitRunner.discover(tool: "gh")

        var reports: [CleanReport] = []
        for id in ctx.store.threadIDs() {
            if let report = await ctx.service.cleanMerged(id: id, gh: gh, includeClosed: closed, dryRun: !yes),
                report.hasWork {
                reports.append(report)
            }
        }
        guard !reports.isEmpty else {
            out("nothing to clean")
            return 0
        }
        for report in reports { for line in report.render() { out(line) } }
        let lookupFailed = reports.contains { $0.state == nil && $0.note != nil }
        if !yes { out("dry run: nothing was changed. `workbench clean --yes` removes what is marked above.") }
        return lookupFailed ? fail(.failed, "GitHub could not be asked about some threads; they were kept.") : 0
    }
}
