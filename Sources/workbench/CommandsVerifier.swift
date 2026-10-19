import Foundation
import WorkbenchCore

extension Commands {
    /// `verifier [id] [--again]`: runs the project's `[verifier]` skill as a separate, bounded Claude turn that
    /// drives the app and leaves proof. Advisory: what it says is a note, never a pass. It costs money, so it runs
    /// once per turn unless `--again`.
    static func verifier(_ args: [String]) async throws -> Int32 {
        var a = Arguments(args)
        let again = a.flag("--again")
        let named = a.positional()
        try a.requireEmpty()
        let ctx = try await Context.load()
        let id = try ctx.threadIDForViewing(named)
        let config = try Config.load(from: ctx.project.configURL)
        guard let verifier = config.verifier else { throw CLIError.refused("\(VerifierRefusal.notConfigured)") }
        let cap = NSDecimalNumber(decimal: verifier.budgetUSD).stringValue
        out("verifying \(id) (advisory; up to $\(cap) and \(verifier.timeoutMin) min)...")
        // Ctrl-C stops the verifier's `claude` instead of leaving it running on its own budget.
        let holder = RunHolder()
        let signals = installStopHandlers(what: "the verifier") { holder.stop() }
        defer { signals.forEach { $0.cancel() } }
        let report: VerifierReport
        do {
            report = try await ctx.service.verifier(id: id, config: config, again: again, attach: { holder.attach($0) })
        } catch let error as VerifierRefusal {
            throw CLIError.refused("\(error)")
        }
        let cost = report.costUSD.map { String(format: "  $%.4f", $0) } ?? ""
        let seconds = String(format: "%.0fs", Double(report.durationMs) / 1000)
        guard report.ok else {
            out("verifier did not finish for turn \(report.turn)\(cost) in \(seconds): \(report.reason ?? "unknown")")
            for file in report.files { out("  proof: \(file.name) (\(file.bytes) bytes)") }
            return 1
        }
        out("verifier finished for turn \(report.turn)\(cost) in \(seconds)")
        for file in report.files { out("  proof: \(file.name) (\(file.bytes) bytes)") }
        out("")
        out(report.report)
        out("")
        out("advisory only: this is a note for you; look at the screenshots yourself")
        return 0
    }
}

extension Commands {
    /// The lines `run` prints for an automatic verifier.
    static func printVerifierNotice(_ notice: RunNotice) {
        switch notice {
        case .verifierStarted(_, let skill):
            out("verifier started: \(skill)")
        case .verifierEnded(let verifier):
            out((verifier.ok ? "verifier finished" : "verifier did not finish: \(verifier.reason ?? "unknown")")
                + (verifier.costUSD.map { String(format: "  $%.4f", $0) } ?? "")
                + "  \(verifier.durationMs / 1000)s  \(verifier.files.count) proof file(s)")
        default:
            break
        }
    }
}

extension Commands {
    /// Whether the verifier can run on work cut from `base`, for judging a screenshot proof before it is paid for.
    static func skillAvailable(_ config: Config, _ ctx: Context, _ base: String) async -> Bool {
        await VerifierSkill.isAvailable(config: config, git: ctx.service.git, repo: ctx.project.root, ref: base)
    }
}
