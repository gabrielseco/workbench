import Foundation
import WorkbenchCore

extension Commands {
    /// `plan [id] [--again] [--model <name>] [--budget <usd>]`: a read-only Claude run that reads the repository at
    /// the thread's base commit against the approved goal and writes the approach. It prints and records the plan
    /// and changes nothing else; the next `run` does not read it yet. It costs money, so it runs once per approved
    /// goal unless `--again`.
    static func plan(_ args: [String]) async throws -> Int32 {
        if args.first == "show" { return try await planShow(Array(args.dropFirst())) }
        if args.first == "edit" { return try await planEdit(Array(args.dropFirst())) }
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
        out("`workbench run` puts it in the first prompt; `workbench plan edit` changes it first.")
        return 0
    }

    /// `plan show [id]`: the latest plan, who wrote it, what it cost and whether it still fits the goal.
    static func planShow(_ args: [String]) async throws -> Int32 {
        var a = Arguments(args)
        let named = a.positional()
        try a.requireEmpty()
        let ctx = try await Context.load()
        let id = try ctx.threadIDForViewing(named)
        guard let view = ctx.service.planShow(id: id) else {
            out("no plan for \(id): `workbench plan` makes one")
            return 0
        }
        var head = "plan:      \(view.plan.source.rawValue)"
        if let model = view.model { head += " (\(model))" }
        if let cost = view.costUSD { head += String(format: "  $%.4f", cost) }
        out(head + "  \(view.plan.ref)")
        switch view.belongsToGoal {
        case false?:
            out("note:      made for an earlier version of the goal; `run` leaves it out (`plan --again` makes a new one)")
        case nil: out("note:      the goal could not be read, so it is not known whether the plan fits it")
        case true?: break
        }
        guard let text = view.text else {
            out("note:      \(view.problem ?? "the plan cannot be read")")
            return 0
        }
        out("")
        out(text)
        return 0
    }

    /// `plan edit [id] [--apply | --from <file>]`: without a flag, copies the latest plan to `plans/draft.md`;
    /// `--apply` records the draft as the newest plan, `--from` records a file's text. No editor is started: every
    /// child Workbench runs has no terminal, so you edit the file yourself.
    static func planEdit(_ args: [String]) async throws -> Int32 {
        var a = Arguments(args)
        let apply = a.flag("--apply")
        let from = try a.value("--from")
        let named = a.positional()
        try a.requireEmpty()
        if apply && from != nil { throw CLIError.usage("--apply and --from are two ways to give the text; pass one") }
        let ctx = try await Context.load()
        let id = try ctx.threadIDForViewing(named)
        do {
            if !apply && from == nil {
                let url = try ctx.service.planDraft(id: id)
                out("draft: \(url.path)")
                out("edit it, then run `workbench plan edit --apply` to make it the plan the next run uses")
                return 0
            }
            let text: String
            if let from {
                let size = (try? FileManager.default.attributesOfItem(atPath: from)[.size] as? Int) ?? 0
                guard size <= Plan.textLimit * 4, let read = try? String(contentsOfFile: from, encoding: .utf8) else {
                    throw PlanRefusal.fileUnreadable("\(from) is missing, not text, or over \(Plan.textLimit * 4) bytes")
                }
                text = read
            } else {
                text = try ctx.service.planDraftText(id: id)
            }
            let result = try await ctx.service.planEdit(id: id, text: text)
            out("plan saved to \(result.ref)\(result.truncated ? "  (cut at \(Plan.textLimit) bytes)" : "")")
            out("`workbench run` puts it in the first prompt")
            return 0
        } catch let error as PlanRefusal {
            throw CLIError.refused("\(error)")
        }
    }
}
