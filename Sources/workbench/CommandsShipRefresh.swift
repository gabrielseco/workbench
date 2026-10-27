import Foundation
import WorkbenchCore

/// What checking the pull request text came to: a proposal, nothing to propose, or a stop (which ends `ship`).
struct RefreshStep {
    var proposal: PRRefreshProposal?
    var stopped = false
}

extension Commands {
    /// For a thread that updates an existing pull request: asks whether its title and description still match
    /// the work and prints what would change. Nothing is written here.
    static func proposeRefresh(plan: ShipPlan, ctx: Context) async throws -> RefreshStep {
        guard let config = try? Config.load(from: ctx.project.configURL) else {
            out("no readable .workbench/config.toml; the pull request text is left as is")
            return RefreshStep()
        }
        out("checking whether the pull request text still matches the work...")
        // Ctrl-C ends the refresh turn; the pull request text is then left as it is.
        let holder = RunHolder()
        let signals = installStopHandlers(what: "the refresh turn") { holder.stop() }
        let result = try await ctx.service.proposePRRefresh(plan: plan, config: config, attach: { holder.attach($0) })
        signals.forEach { $0.cancel() }
        restoreDefaultSignals()
        if holder.isStopRequested { return RefreshStep(stopped: true) }
        if let why = result.fallback {
            out("could not check the pull request text (\(why)); it is left as is")
            return RefreshStep()
        }
        guard let proposal = result.proposal, !proposal.isEmpty else {
            out("the pull request text still matches the work; it is left as is")
            return RefreshStep()
        }
        out("proposed update to the pull request text:")
        for line in proposal.render() { out("  " + line) }
        // A Codex turn can read files outside its folder, so the whole text it would publish is shown, not only the change.
        if config.resolvedShipAgent.provider != .claude {
            out("the pull request text after the update:")
            out("title:   \(proposal.updated.title)")
            out("")
            out(proposal.updated.body.trimmingCharacters(in: .newlines))
            out("")
        }
        return RefreshStep(proposal: proposal)
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

/// What describing the change came to: a description, the goal-based fallback (nil), or a stop (which ends `ship`).
struct DescribeStep {
    var description: PRDescription?
    var stopped = false
}

extension Commands {
    /// Asks the model for the pull request's description. Ctrl-C or `workbench stop` ends the turn and reports it.
    static func describeForShip(plan: ShipPlan, ctx: Context) async throws -> DescribeStep {
        guard let config = try? Config.load(from: ctx.project.configURL) else {
            out("no readable .workbench/config.toml; using the goal-based description")
            return DescribeStep()
        }
        out("describing the change...")
        let holder = RunHolder()
        let signals = installStopHandlers(what: "the description turn") { holder.stop() }
        let described = try await ctx.service.describePR(plan: plan, config: config, attach: { holder.attach($0) })
        signals.forEach { $0.cancel() }
        restoreDefaultSignals()
        if holder.isStopRequested { return DescribeStep(stopped: true) }
        if let why = described.fallback { out("could not describe the change (\(why)); using the goal-based description") }
        return DescribeStep(description: described.description)
    }
}
