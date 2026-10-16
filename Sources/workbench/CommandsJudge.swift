import Foundation
import WorkbenchCore

/// The running `claude`, reachable from a signal handler; a stop that arrives before it has started is kept.
private final class RunHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var run: ProcessRun?
    private var stopRequested = false

    func attach(_ new: ProcessRun) {
        lock.lock()
        run = new
        let stop = stopRequested
        lock.unlock()
        if stop { new.stop() }
    }

    func stop() {
        lock.lock()
        stopRequested = true
        let current = run
        lock.unlock()
        current?.stop()
    }
}

extension Commands {
    /// `judge [id] [--again] [--model <name>] [--budget <usd>]`: ask a second, read-only Claude run whether the
    /// evidence (the check, the verify step, its screenshots and the diff) shows each criterion holds. Advisory:
    /// it prints and records a verdict next to your own ticks and never changes what `accept` or `ship` do. It
    /// costs money, so it runs once per turn unless `--again`.
    static func judge(_ args: [String]) async throws -> Int32 {
        var a = Arguments(args)
        let again = a.flag("--again")
        let model = try a.value("--model")
        let budgetText = try a.value("--budget")
        let named = a.positional()
        try a.requireEmpty()
        var budget = Judge.budgetUSD
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
        out("judging \(id) (advisory; read-only, up to $\(NSDecimalNumber(decimal: budget).stringValue))...")
        // Ctrl-C stops the judge's `claude` instead of leaving it running on its own budget.
        let holder = RunHolder()
        let signals = installStopHandlers(what: "the judge") { holder.stop() }
        defer { signals.forEach { $0.cancel() } }
        let result: JudgeResult
        do {
            result = try await ctx.service.judge(
                id: id, config: config, again: again, budget: budget, model: model, attach: { holder.attach($0) })
        } catch let error as JudgeRefusal {
            if case .invalidModel = error { throw CLIError.usage("\(error)") }
            throw CLIError.refused("\(error)")
        }
        let cost = result.costUSD.map { String(format: "  $%.4f", $0) } ?? ""
        guard result.verdict != nil else {
            out("no verdict for turn \(result.turn)\(cost): \(result.failure ?? "unknown")")
            return 1
        }
        out("verdict for turn \(result.turn)\(cost)")
        let report = await ReviewLoader(project: ctx.project, git: ctx.git).load(id: id)
        for line in report.judgeLines().dropFirst() { out(line) }
        out("")
        out("advisory only: `workbench review` shows it beside your own checks; accept and ship ignore it")
        return 0
    }
}
