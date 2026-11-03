import Foundation

extension ThreadService {
    /// A draft goal file: Workbench's front matter (id, status draft, base, spend, timeout, model) and `body`.
    func goalText(
        id: String, title: String, base: String, pushTo: String? = nil, config: Config?, settings: GoalSettings = GoalSettings(),
        body: GoalBody
    ) -> String {
        let pushToLine = pushTo.map { "\npush_to: \($0)" } ?? ""
        // A budget only when the file or the config asks for one: a subscription has no dollars to cap, and Codex cannot enforce any.
        let config = config ?? (try? Config.load(from: project.configURL))
        let configured = config?.defaultBudgetConfigured == true ? config?.defaultBudgetUSD : nil
        let budget = settings.timeoutOnly ? nil : (settings.budgetUSD ?? configured)
        let spendLine =
            budget.map { "budget_usd: " + NSDecimalNumber(decimal: $0).stringValue } ?? "spend_policy: timeout_only"
        let modelLine =
            settings.model.map { "model: \($0)" }
            ?? "# model: opus   (optional; unset = the config's model, else the claude CLI default)"

        let header = """
            ---
            id: \(id)
            \(FrontMatterLine(key: "title", value: title).rendered)
            status: draft
            base: \(base)\(pushToLine)
            \(spendLine)
            turn_timeout_min: \(settings.turnTimeoutMin ?? 30)\(settings.quick ? "\nquick: true" : "")
            \(modelLine)
            ---


            """
        return header + body.rendered
    }
}
