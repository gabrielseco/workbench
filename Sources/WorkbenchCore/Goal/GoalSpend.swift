import Foundation

extension GoalFile {
    static func spendPolicyProblem(_ raw: String) -> String {
        "'spend_policy' must be 'timeout_only' (or left out for a 'budget_usd' cap), found '\(raw)'"
    }

    /// `budget_usd` (a hard cap) or `spend_policy: timeout_only`, never both and never neither. Nil after a problem.
    static func spendValue(
        _ policy: FrontMatterLine?, budget: FrontMatterLine?, add: (GoalProblem.Code, Int?, String) -> Void
    ) -> AgentSpend? {
        if let policy {
            guard policy.value == "timeout_only" else {
                add(.invalidValue, policy.lineNumber, spendPolicyProblem(policy.value))
                return nil
            }
            if let budget {
                add(
                    .invalidValue, budget.lineNumber,
                    "'budget_usd' and 'spend_policy: timeout_only' exclude each other: remove 'budget_usd', "
                        + "since nothing would enforce it")
                return nil
            }
            return .timeoutOnly
        }
        guard let budget else {
            add(.missingKey, nil, "missing required key 'budget_usd' (or 'spend_policy: timeout_only')")
            return nil
        }
        guard !budget.value.isEmpty else {
            add(.invalidValue, budget.lineNumber, "'budget_usd' must not be empty")
            return nil
        }
        guard let d = budgetValue(budget.value) else {
            add(.invalidValue, budget.lineNumber, budgetProblem(budget.value))
            return nil
        }
        return .hardCap(d)
    }
}
