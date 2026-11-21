import Foundation

extension SeriesReport {
    static let builtLimit = 1_200
    static let saidLimit = 700
    static let filesShown = 12
    static let concernsShown = 5

    /// The report as Markdown to read top to bottom: the summary and the merge order first, then one section per step with what it
    /// built, what the review found and what answered each finding. Text that came from an agent is scrubbed of machine paths and
    /// credentials and cut, and the files it was cut from are named.
    public var markdown: String {
        var out: [String] = []
        let clean = steps.filter { $0.state.isClean }.count
        out.append("# Series \(name): report")
        out.append("")
        var summary = "Generated \(generated). \(clean) of \(steps.count) steps clean. "
        summary += "Coding turns cost \(Self.money(totalCostUSD, unknown: totalCostUnknown))"
        if let budgetUSD { summary += " of the \(Self.money(budgetUSD)) series budget" }
        summary += " (the Codex reviews and judge runs have no price and are not counted)."
        out.append(summary)
        out.append("")
        out.append("| Step | Goal | State | Pull request | Review rounds | Cost |")
        out.append("|---|---|---|---|---|---|")
        for step in steps {
            let rounds = step.rounds.map { ($0.verdict ?? "none").uppercased() }.joined(separator: " → ")
            out.append(
                "| \(step.number) | \(Self.cell(step.goalTitle)) | \(Self.stateWord(step.state)) | "
                    + "\(step.pullRequest ?? "none") | \(rounds.isEmpty ? "none" : rounds) | "
                    + "\(Self.money(step.costUSD, unknown: step.costUnknown)) |")
        }
        let open = steps.compactMap { step in step.pullRequest.map { "\(step.number). \($0)" } }
        if !open.isEmpty {
            out += ["", "## Merge in this order", ""] + open
            out.append("")
            out.append(
                "Merge a step, then run `workbench series rebase \(name)` before the next one: it moves the next pull "
                    + "request onto the base.")
        }
        for step in steps { out += Self.section(step) }
        return out.joined(separator: "\n") + "\n"
    }

    private static func section(_ step: SeriesReportStep) -> [String] {
        var out = ["", "## Step \(step.number): \(step.goalTitle)", ""]
        guard step.thread != nil else {
            return out + ["Not started."]
        }
        out.append("State: \(stateWord(step.state)). Project `\(step.project)`, thread `\(step.thread ?? "")`.")
        if let pr = step.pullRequest { out.append("Pull request: \(pr)") }
        var facts: [String] = []
        if let additions = step.additions, let deletions = step.deletions {
            facts.append("+\(additions) −\(deletions) in \(step.files.count) file\(step.files.count == 1 ? "" : "s")")
        }
        facts.append("\(step.turns) turn\(step.turns == 1 ? "" : "s")")
        facts.append(money(step.costUSD, unknown: step.costUnknown))
        if let check = step.check { facts.append("check \(check)") }
        if let verifier = step.verifier { facts.append("verifier \(verifier)") }
        let judged = step.criteria.filter { $0.met != nil }
        if !judged.isEmpty {
            let met = judged.filter { $0.met == true }.count
            // Its reading is of one turn; the review follow-ups came after it and may have fixed what it found.
            let when = step.judgeTurn.map { " after turn \($0)" } ?? ""
            let later = step.rounds.contains { $0.fix != nil } ? ", before the review fixes" : ""
            facts.append("judge\(when)\(later): \(met) of \(judged.count) criteria met")
        }
        out.append(facts.joined(separator: " · "))
        if !step.files.isEmpty {
            let shown = step.files.prefix(filesShown).map { "`\($0)`" }.joined(separator: ", ")
            let more = step.files.count > filesShown ? ", and \(step.files.count - filesShown) more" : ""
            out += ["", "Files: \(shown)\(more)"]
        }
        if let built = step.built, !built.isEmpty {
            out += ["", "**What it built**, in the agent's words:", ""] + quote(built, limit: builtLimit, thread: step.thread)
        }
        if !step.criteria.isEmpty {
            out += ["", "**Criteria**", ""]
            for criterion in step.criteria {
                let mark = criterion.met == true ? "✔" : (criterion.met == false ? "✘" : "?")
                out.append("- \(mark) \(criterion.id): \(cell(criterion.text))")
            }
        }
        if !step.judgeConcerns.isEmpty {
            out += ["", "**Judge concerns** (advice, not a gate)", ""]
            out += step.judgeConcerns.prefix(concernsShown).map { "- \(cell($0))" }
        }
        if !step.rounds.isEmpty {
            out += ["", "**Review**", ""]
            for round in step.rounds { out += lines(for: round) }
        }
        if !step.manual.isEmpty {
            out += ["", "**Also pushed to this branch outside the review rounds** (a CI fix, or work done by hand)", ""]
            for fix in step.manual {
                out.append("- `\(fix.thread)` (\(money(fix.costUSD, unknown: fix.costUnknown)))")
                for commit in fix.commits { out.append("  - commit: \(cell(commit))") }
                if let said = fix.said, !said.isEmpty {
                    out += quote(said, limit: saidLimit, thread: fix.thread).map { "  " + $0 }
                }
            }
        }
        return out
    }

    private static func lines(for round: SeriesReportRound) -> [String] {
        var out = ["- Round \(round.round): **\((round.verdict ?? "no verdict").uppercased())**"]
        for finding in round.findings { out.append("  - \(finding.severity) \(cell(finding.title))") }
        if round.verdict == "fix", round.findings.isEmpty { out.append("  - (the findings are in the file below)") }
        if let fix = round.fix {
            out.append("  - Answered by `\(fix.thread)` (\(money(fix.costUSD, unknown: fix.costUnknown))):")
            for commit in fix.commits { out.append("    - commit: \(cell(commit))") }
            if let said = fix.said, !said.isEmpty {
                out += quote(said, limit: saidLimit, thread: fix.thread).map { "    " + $0 }
            }
        } else if round.verdict == "fix" {
            out.append("  - No review-loop follow-up answered this round (see the work done by hand below, if any).")
        }
        if let file = round.findingsFile { out.append("  - Whole answer: `\(file)`") }
        return out
    }

    /// An agent's text as a quote: scrubbed, cut at `limit` with the cut said and where the whole account is (`workbench log <thread>`).
    private static func quote(_ text: String, limit: Int, thread: String?) -> [String] {
        let clean = scrubbed(text).trimmingCharacters(in: .whitespacesAndNewlines)
        let cut = clean.count > limit
        let body = cut ? String(clean.prefix(limit)) + "…" : clean
        var lines = body.split(separator: "\n", omittingEmptySubsequences: false).map { $0.isEmpty ? ">" : "> \($0)" }
        if cut, let thread { lines.append("> (cut; the whole account: `workbench log \(thread)`)") }
        return lines
    }

    /// Paths of the machine, credentials of the known forms (URL credentials, authorization headers, GitHub tokens, query-string tokens)
    /// and `NAME_TOKEN=value` pairs. Not a promise about every secret an agent might print: the files named in the report hold the
    /// whole text.
    static func scrubbed(_ text: String) -> String {
        let pairs = #"(?i)\b([A-Z0-9_]*(?:TOKEN|SECRET|PASSWORD|API_?KEY)[A-Z0-9_]*\s*[=:]\s*)[^\s,;'")]+"#
        let hidden = ThreadService.withoutCredentials(PRBodyBuilder.scrub(text))
        return hidden.replacingOccurrences(of: pairs, with: "$1<redacted>", options: .regularExpression)
    }

    private static func cell(_ text: String) -> String {
        scrubbed(text).replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "|", with: "/")
    }

    /// A cost with a turn that reported none is a lower bound and says so.
    static func money(_ value: Double, unknown: Bool = false) -> String {
        String(format: "$%.2f", value) + (unknown ? "+ (a turn reported no cost)" : "")
    }

    static func stateWord(_ state: SeriesStepState) -> String {
        switch state {
        case .pending: "not started"
        case .running: "running"
        case .waiting(_, let reason): "waiting (\(reason))"
        case .clean: "clean"
        case .stopped(_, let reason): "STOPPED (\(reason))"
        }
    }
}
