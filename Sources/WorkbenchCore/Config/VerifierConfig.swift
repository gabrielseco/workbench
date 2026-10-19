import Foundation

/// `[verifier]`: the project's own skill, run as a separate turn that drives the app and leaves proof
/// (docs/plan/P10-skill-verifier.md). On by default: no table means the default skill, `enabled = false` means none.
public struct VerifierConfig: Sendable, Equatable {
    public static let defaultBudgetUSD: Decimal = 1
    public static let defaultTimeoutMin = 10
    public static let defaultTools = ["Read"]
    public static let defaultSkill = ".claude/skills/verify/SKILL.md"

    /// A repo-relative path to the skill file, read from the base commit. Nothing is discovered: a project without
    /// the file gets no verifier turn.
    public var skill: String
    /// Claude Code permission patterns the verifier may use, and only these. Never the skill's own `allowed-tools`.
    public var tools: [String]
    /// `--model` for the verifier; unset falls back to the coding `model`.
    public var model: String?
    public var budgetUSD: Decimal
    public var timeoutMin: Int

    public init(
        skill: String = VerifierConfig.defaultSkill, tools: [String] = VerifierConfig.defaultTools, model: String? = nil,
        budgetUSD: Decimal = VerifierConfig.defaultBudgetUSD, timeoutMin: Int = VerifierConfig.defaultTimeoutMin
    ) {
        self.skill = skill
        self.tools = tools
        self.model = model
        self.budgetUSD = budgetUSD
        self.timeoutMin = timeoutMin
    }

    static let table = "verifier"
    static let keys: Set<String> = ["skill", "tools", "model", "enabled", "budget_usd", "timeout_min"]

    /// Whether `Config.parse` should leave this table to `parse(_:fail:)`.
    static func owns(table name: String) -> Bool { name == table }

    /// Why a tool pattern cannot go in `tools`, nil when it can. `Bash` with no command to confine it would let the
    /// model run anything, which is what the project's own helpers are listed to avoid.
    static func toolProblem(_ pattern: String) -> String? {
        guard Config.isToolPattern(pattern) else { return "is not a tool name or 'Name(pattern)'" }
        guard pattern.hasPrefix("Bash") else { return nil }
        let rest = pattern.dropFirst("Bash".count)
        if rest.isEmpty { return "gives the model any command; name the helpers, like \"Bash(scripts/snap.sh:*)\"" }
        guard rest.hasPrefix("("), rest.hasSuffix(")") else { return nil }
        let inner = rest.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
        if inner.allSatisfy({ $0 == "*" || $0 == ":" }) {
            return "gives the model any command; name the helpers, like \"Bash(scripts/snap.sh:*)\""
        }
        return nil
    }

    /// Nil only when the project turned the verifier off with `enabled = false`.
    static func parse(_ document: TOMLDocument, fail: ReviewConfig.Fail) -> VerifierConfig? {
        guard let table = document.tables[table] else { return VerifierConfig() }
        for (key, entry) in table.entries.sorted(by: { $0.key < $1.key }) where !keys.contains(key) {
            fail(.unknownKey, entry.line, "unknown key '\(key)' in [verifier]")
        }

        var enabled = true
        if let entry = table.entries["enabled"] {
            if case .bool(let value) = entry.value {
                enabled = value
            } else {
                fail(.wrongType, entry.line, "'enabled' must be true or false, found \(entry.value.typeName)")
            }
        }

        var skill = defaultSkill
        if let entry = table.entries["skill"] {
            if case .string(let value) = entry.value {
                if value.isEmpty {
                    fail(.invalidValue, entry.line, "'skill' must be a path to the skill file, not empty")
                } else if let reason = PRReviewConfig.checklistProblem(value) {
                    fail(.invalidValue, entry.line, "'skill' \(reason)")
                } else if value.split(separator: "/").contains(".") {
                    // Git lists the canonical path, so a "./" part would make a committed file look missing.
                    fail(.invalidValue, entry.line, "'skill' must be a path without '.' parts")
                } else {
                    skill = value
                }
            } else {
                fail(.wrongType, entry.line, "'skill' must be a string, found \(entry.value.typeName)")
            }
        }

        var tools = defaultTools
        if let entry = table.entries["tools"] {
            if case .array(let items) = entry.value {
                var values: [String] = []
                var wrongType = false
                for item in items {
                    guard case .string(let value) = item else {
                        fail(.wrongType, entry.line, "'tools' must contain only strings, found \(item.typeName)")
                        wrongType = true
                        break
                    }
                    values.append(value)
                }
                if !wrongType {
                    if values.isEmpty { fail(.invalidValue, entry.line, "'tools' must list at least one tool") }
                    for pattern in values {
                        if let reason = toolProblem(pattern) {
                            fail(.invalidValue, entry.line, "'tools' entry '\(pattern)' \(reason)")
                        }
                    }
                    tools = values
                }
            } else {
                fail(.wrongType, entry.line, "'tools' must be an array of strings, found \(entry.value.typeName)")
            }
        }

        var model: String?
        if let entry = table.entries["model"] {
            if case .string(let value) = entry.value {
                if SafeNames.isModelName(value) {
                    model = value
                } else {
                    fail(.invalidValue, entry.line, "'model' must be a model name or alias like \"sonnet\"")
                }
            } else {
                fail(.wrongType, entry.line, "'model' must be a string, found \(entry.value.typeName)")
            }
        }

        var budget = defaultBudgetUSD
        if let entry = table.entries["budget_usd"] {
            switch entry.value {
            case .int(let n) where n > 0: budget = Decimal(n)
            case .number(let d) where d > 0: budget = d
            default: fail(.invalidValue, entry.line, "'budget_usd' must be a positive number")
            }
        }

        var timeout = defaultTimeoutMin
        if let entry = table.entries["timeout_min"] {
            if case .int(let n) = entry.value, (1...240).contains(n) {
                timeout = n
            } else {
                fail(.invalidValue, entry.line, "'timeout_min' must be a whole number of minutes from 1 to 240")
            }
        }

        guard enabled else { return nil }
        return VerifierConfig(skill: skill, tools: tools, model: model, budgetUSD: budget, timeoutMin: timeout)
    }
}
