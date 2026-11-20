import Foundation

/// What `task.md` says about the gate (docs/spec/tasks.md, "The gate").
extension TaskDefinition {
    /// The worker's instructions and the gate's criteria. The `## Gate` section is the criteria, not the worker's instructions: the
    /// worker does not see it. Only for `gate: inline`; without it the body is the worker's whole, as it always was, whatever
    /// headings it has.
    static func splitBody(
        _ body: String, gate: FrontMatterLine?, line: Int, add: (Int?, String) -> Void
    ) -> (instructions: String, gate: String?) {
        guard gate?.value == "inline" else { return (body, nil) }
        let (instructions, section) = splitGateSection(body)
        if !body.isEmpty, instructions.isEmpty { add(line, "no instructions besides the '## Gate' section") }
        return (instructions, section)
    }

    /// `run_budget`, and the gate's need for the script that names its candidates.
    static func gateBudget(
        _ definition: TaskDefinition, entry: (String) -> FrontMatterLine?, add: (Int?, String) -> Void
    ) -> Decimal? {
        if definition.gate != nil, definition.pending == nil, let e = entry("gate") {
            add(e.lineNumber, "'gate' needs 'pending': the gate decides which of the script's units the worker takes")
        }
        guard let e = entry("run_budget") else { return nil }
        guard definition.gate != nil else {
            if entry("gate") == nil { add(e.lineNumber, "'run_budget' is for a task with a 'gate'") }
            return nil
        }
        guard let budget = GoalFile.budgetValue(e.value) else {
            add(e.lineNumber, "'run_budget' must be a positive number, found '\(e.value)'")
            return nil
        }
        return budget
    }

    /// The body without its `## Gate` section, and that section's text (nil when there is none). The section runs to the next `## `
    /// line or the end.
    static func splitGateSection(_ body: String) -> (instructions: String, gate: String?) {
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "## Gate" }) else {
            return (body, nil)
        }
        let end = lines[(start + 1)...].firstIndex { $0.hasPrefix("## ") } ?? lines.endIndex
        let rest = lines[..<start] + lines[end...]
        return (
            rest.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
            lines[(start + 1)..<end].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// `gate`, `gate_allow` and `gate_rounds`, for a `fix: pr` task only: the gate runs before the worker's thread, which only a
    /// `fix: pr` task starts. `gate_allow` and `gate_rounds` mean nothing without it, so they are refused as the history key is.
    static func gate(
        _ gate: FrontMatterLine?, allow: FrontMatterLine?, rounds: FrontMatterLine?, section: String?, fix: TaskFix,
        add: (Int?, String) -> Void
    ) -> TaskGate? {
        guard let gate else {
            for e in [allow, rounds] {
                if let e { add(e.lineNumber, "'\(e.key)' is for a task with a 'gate'") }
            }
            return nil
        }
        guard fix == .pr else {
            add(gate.lineNumber, "'gate' is for 'fix: pr': it decides which units the worker's thread takes")
            return nil
        }
        var result: TaskGate?
        if gate.value == "inline" {
            if let section, !section.isEmpty {
                result = TaskGate(source: .inline(section))
            } else {
                add(gate.lineNumber, "'gate: inline' needs a '## Gate' section with the criteria in the body")
            }
        } else if isSafeRelativePath(gate.value), !gate.value.hasSuffix("/") {
            result = TaskGate(source: .file(gate.value))
        } else {
            add(gate.lineNumber, "'gate' must be 'inline' or a file path inside the project, found '\(gate.value)'")
        }
        if let allow {
            let items = list(allow.value)
            if items.isEmpty || items.count > TaskGate.maxAllow {
                add(allow.lineNumber, "'gate_allow' must list 1 to \(TaskGate.maxAllow) commands, found '\(allow.value)'")
            } else if let bad = items.first(where: { !TaskGate.isSafeAllow($0) }) {
                add(
                    allow.lineNumber,
                    "'gate_allow' has '\(bad)', which is not a plain command pattern: words, and `:*` at the end to allow any "
                        + "arguments")
            } else if Set(items).count != items.count {
                add(allow.lineNumber, "'gate_allow' names a command twice, found '\(allow.value)'")
            } else {
                result?.allow = items
            }
        }
        if let rounds {
            if let n = Int(rounds.value), TaskGate.roundsRange.contains(n) {
                result?.rounds = n
            } else {
                let range = "\(TaskGate.roundsRange.lowerBound) to \(TaskGate.roundsRange.upperBound)"
                add(rounds.lineNumber, "'gate_rounds' must be a whole number from \(range), found '\(rounds.value)'")
            }
        }
        return result
    }
}
