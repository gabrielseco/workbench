import Foundation
import WorkbenchCore

extension Commands {
    /// For a thread that updates an existing pull request: asks whether its title and description still match
    /// the work and prints what would change. Nothing is written here.
    static func proposeRefresh(plan: ShipPlan, ctx: Context) async throws -> PRRefreshProposal? {
        guard let config = try? Config.load(from: ctx.project.configURL) else {
            out("no readable .workbench/config.toml; the pull request text is left as is")
            return nil
        }
        out("checking whether the pull request text still matches the work...")
        // Ctrl-C ends the refresh turn; the pull request text is then left as it is.
        let holder = RunHolder()
        let signals = installStopHandlers(what: "the refresh turn") { holder.stop() }
        let result = try await ctx.service.proposePRRefresh(plan: plan, config: config, attach: { holder.attach($0) })
        signals.forEach { $0.cancel() }
        restoreDefaultSignals()
        if let why = result.fallback {
            out("could not check the pull request text (\(why)); it is left as is")
            return nil
        }
        guard let proposal = result.proposal, !proposal.isEmpty else {
            out("the pull request text still matches the work; it is left as is")
            return nil
        }
        out("proposed update to the pull request text:")
        for line in proposal.render() { out("  " + line) }
        return proposal
    }

    /// Editing a pull request people have read needs its own yes, apart from publishing. `--yes` alone never
    /// edits it; `--refresh-description` is the explicit consent for scripts.
    static func askRefresh(yes: Bool, flag: Bool, interactive: Bool) -> Bool {
        if flag { return true }
        if yes || !interactive { return false }
        print("Update the pull request title and description as shown? [y/N] ", terminator: "")
        return Confirmation.ask(yes: false, interactive: true, readLine: { readLine() }) == .proceed
    }
}
