import Foundation
import WorkbenchCore

extension Commands {
    /// `plan [id] [--again] [--model <name>] [--budget <usd>]`: a read-only Claude run that reads the repository at
    /// the thread's base commit against the approved goal and writes the approach. It prints and records the plan
    /// and changes nothing else; the next `run` does not read it yet. It costs money, so it runs once per approved
    /// goal unless `--again`.
    static func plan(_ args: [String]) async throws -> Int32 {
        var a = Arguments(args)
        let again = a.flag("--again")
        let model = try a.value("--model")
        let budgetText = try a.value("--budget")
        let named = a.positional()
        try a.requireEmpty()
        var budget = Plan.budgetUSD
        if let budgetText {
            guard budgetText.range(of: #"^[0-9]+(\.[0-9]+)?$"#, options: .regularExpression) != nil,
                let value = Decimal(string: budgetText, locale: Locale(identifier: "en_US_POSIX")), value > 0,
                value <= RunOptions.budgetCeilingUSD
            else { throw CLIError.usage("--budget needs a positive number of dollars, at most \(RunOptions.budgetCeilingUSD)") }
            budget = value
        }
        let ctx = try await Context.load()
        let id = try ctx.threadIDForViewing(named)
        let config = try Config.load(from: ctx.project.configURL)
        out("planning \(id) (read-only; up to $\(NSDecimalNumber(decimal: budget).stringValue))...")
        // Ctrl-C stops the plan's `claude` instead of leaving it running on its own budget.
        let holder = RunHolder()
        let signals = installStopHandlers(what: "the plan") { holder.stop() }
        defer { signals.forEach { $0.cancel() } }
        let result: PlanResult
        do {
            result = try await ctx.service.plan(
                id: id, config: config, again: again, budget: budget, model: model, attach: { holder.attach($0) })
        } catch let error as PlanRefusal {
            if case .invalidModel = error { throw CLIError.usage("\(error)") }
            throw CLIError.refused("\(error)")
        }
        if let warning = result.warning { out("note: \(warning)") }
        let cost = result.costUSD.map { String(format: "  $%.4f", $0) } ?? ""
        guard let text = result.text, let ref = result.ref else {
            out("no plan\(cost): \(result.failure ?? "unknown")")
            return 1
        }
        out("plan saved to \(ref)\(cost)\(result.truncated ? "  (cut at \(Plan.textLimit) bytes)" : "")")
        out("")
        out(text)
        out("`workbench run` does not read it yet.")
        return 0
    }
}
