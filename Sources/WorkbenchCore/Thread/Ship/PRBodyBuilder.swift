import Foundation

/// The title and description `ship` will give the pull request.
public struct PRBody: Sendable, Equatable {
    public var title: String
    public var body: String
}

/// Builds a PR title and body from the goal and the latest check outcome. Pure: no git, no files, no log.
/// Without a `description` the text comes from the approved goal alone. With one (the describing turn's
/// words, see `PRDescriber`) its title and summary replace the goal's request, but the criteria table and
/// the check line are still derived here from the real check, never taken from the model. The check is
/// shown as pass or fail only, so its output (which may hold paths or secrets) cannot reach a page others
/// read.
public enum PRBodyBuilder {
    public static let titleLimit = 72

    /// - Parameters:
    ///   - template: the repository's PR template text, nil when it has none.
    ///   - lastTurn: the newest turn; a check from an earlier turn does not back a verdict.
    public static func build(
        goal: Goal, check: Review.Check?, template: String?, lastTurn: Int? = nil, description: PRDescription? = nil
    ) -> PRBody {
        let request =
            description.map { described($0) }
            ?? scrub(goal.request).trimmingCharacters(in: .whitespacesAndNewlines)
        let checkLine = checkLine(check)
        var criteria = criteriaList(goal.criteria)
        if !goal.criteria.isEmpty {
            let statuses = CriteriaStatus.evaluate(
                criteria: goal.criteria, check: check, lastTurn: lastTurn ?? check?.turn ?? 0)
            // The checklist stays as the reviewer's to tick; the table says who verifies each line.
            criteria += "\n\n" + CriteriaStatus.summary(statuses, check: check) + "\n\n"
                + CriteriaStatus.markdown(statuses) { oneLine(scrub($0)) }
        }
        let testing = [checkLine, criteria].filter { !$0.isEmpty }.joined(separator: "\n\n")

        let body: String
        if let template, !template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body = fill(template: template, summary: request, why: planTask(in: request), testing: testing)
        } else {
            var sections = ["## Summary\n\n" + request]
            if !criteria.isEmpty { sections.append("## Criteria\n\n" + criteria) }
            sections.append("## Check\n\n" + checkLine)
            body = sections.joined(separator: "\n\n")
        }
        // The template is the repository's text, which can carry paths too.
        return PRBody(title: title(description?.title ?? goal.title), body: scrub(body) + "\n")
    }

    /// The model's summary, then what a reviewer should look at.
    static func described(_ description: PRDescription) -> String {
        var parts = [scrub(description.summary).trimmingCharacters(in: .whitespacesAndNewlines)]
        if !description.decisions.isEmpty {
            parts.append("### Decisions to review\n\n" + bullets(description.decisions))
        }
        if !description.deviations.isEmpty {
            parts.append("### Differences from the goal\n\n" + bullets(description.deviations))
        }
        return parts.joined(separator: "\n\n")
    }

    private static func bullets(_ items: [String]) -> String {
        items.map { "- " + oneLine(scrub($0)) }.joined(separator: "\n")
    }

    // MARK: Title

    static func title(_ raw: String) -> String {
        let firstLine = raw.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let flat = scrub(firstLine).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !flat.isEmpty else { return "Workbench task" }
        guard flat.count > titleLimit else { return flat }
        let head = String(flat.prefix(titleLimit))
        // The cut falls on a word boundary when the next character is a space or a space precedes it.
        let atBoundary = flat[flat.index(flat.startIndex, offsetBy: titleLimit)] == " "
        let cut = atBoundary ? head : (head.lastIndex(of: " ").map { String(head[..<$0]) } ?? head)
        return cut.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:-"))
    }

    // MARK: Pieces

    static func checkLine(_ check: Review.Check?) -> String {
        guard let check else { return "Check: not run" }
        var detail: [String] = []
        let verdict: String
        switch check.result {
        case "passed": verdict = "passed"
        case "failed": verdict = "failed"
        case "timed_out": verdict = "timed out"
        case "stopped": verdict = "stopped before it finished"
        case "interrupted": verdict = "interrupted, no result"
        default: verdict = "no result"
        }
        if let code = check.exitCode { detail.append("exit \(code)") }
        if let ms = check.durationMs { detail.append("\(ms / 1000)s") }
        return "Check: \(verdict)" + (detail.isEmpty ? "" : " (\(detail.joined(separator: ", ")))")
    }

    static func criteriaList(_ criteria: [Criterion]) -> String {
        criteria.map { c in
            var item = "- [ ] " + oneLine(scrub(c.text))
            let proof = oneLine(scrub(c.proof))
            if !proof.isEmpty { item += "\n  - proven by: " + proof }
            return item
        }.joined(separator: "\n")
    }

    /// The `(Plan: …)` line a goal may carry, without its wrapper.
    static func planTask(in request: String) -> String? {
        for raw in request.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("(") { line.removeFirst() }
            guard line.lowercased().hasPrefix("plan:") else { continue }
            line.removeFirst("plan:".count)
            if line.hasSuffix(")") { line.removeLast() }
            let text = line.trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { return text }
        }
        return nil
    }

    // MARK: Template

    /// Keeps the template's headings in order. `Summary`, `Why`/`Context` and `Testing` are filled; any other
    /// section keeps the template's own text. HTML comments are instructions to the author and are dropped.
    static func fill(template: String, summary: String, why: String?, testing: String) -> String {
        let text = template.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)

        struct Section {
            var heading: String?
            var lines: [String] = []
        }
        var sections = [Section()]
        var fence: (char: Character, length: Int)?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let wasFenced = fence != nil
            fence = nextFence(after: fence, line: line)
            let fenced = wasFenced || fence != nil
            if !fenced, line.hasPrefix("#"), headingName(line) != nil {
                sections.append(Section(heading: line))
            } else {
                sections[sections.count - 1].lines.append(line)
            }
        }

        // A template without these headings must not swallow the content a reader needs.
        let names = Set(sections.compactMap { $0.heading.flatMap(headingName) })
        if !names.contains("summary") {
            sections.insert(Section(heading: "## Summary"), at: 1)  // 0 is the text before any heading
        }
        if !names.contains("testing") { sections.append(Section(heading: "## Testing")) }

        var parts: [String] = []
        for section in sections {
            var content = trimBlankLines(section.lines)
            if let heading = section.heading {
                switch headingName(heading) {
                case "summary": content = summary
                case "testing": content = testing
                case "why", "context": if let why { content = why }
                default: break
                }
                parts.append(content.isEmpty ? heading : heading + "\n\n" + content)
            } else if !content.isEmpty {
                parts.append(content)
            }
        }
        return parts.joined(separator: "\n\n")
    }

    /// Tracks a fenced code block: up to three spaces of indent, three or more backticks or tildes, and a
    /// closing fence of the same character that is at least as long and carries nothing else.
    static func nextFence(after open: (char: Character, length: Int)?, line: String)
        -> (char: Character, length: Int)? {
        let indent = line.prefix { $0 == " " }.count
        guard indent <= 3 else { return open }
        let rest = line.dropFirst(indent)
        guard let first = rest.first, first == "`" || first == "~" else { return open }
        let run = rest.prefix { $0 == first }.count
        guard run >= 3 else { return open }
        if let open {
            let closes = first == open.char && run >= open.length
                && rest.dropFirst(run).allSatisfy { $0 == " " || $0 == "\t" }
            return closes ? nil : open
        }
        // A backtick fence's info string cannot hold a backtick, which keeps inline code from opening one.
        if first == "`", rest.dropFirst(run).contains("`") { return nil }
        return (first, run)
    }

    /// Lower-cased heading text for an ATX heading (`## Summary`), nil when the line is not one.
    static func headingName(_ line: String) -> String? {
        let hashes = line.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = line.dropFirst(hashes.count)
        guard rest.first == " " else { return nil }
        var name = rest.trimmingCharacters(in: .whitespaces)
        // `## Testing ##` closes the heading with hashes that are not part of its name.
        while name.hasSuffix("#") { name.removeLast() }
        return name.trimmingCharacters(in: .whitespaces).lowercased()
    }

    // MARK: Text

    /// Drops blank lines at both ends and keeps the indentation of the first real line.
    private static func trimBlankLines(_ lines: [String]) -> String {
        let isBlank: (String) -> Bool = { $0.allSatisfy(\.isWhitespace) }
        guard let first = lines.firstIndex(where: { !isBlank($0) }),
            let last = lines.lastIndex(where: { !isBlank($0) })
        else { return "" }
        var kept = Array(lines[first...last])
        kept[kept.count - 1] = kept[kept.count - 1].replacingOccurrences(
            of: "[ \\t]+$", with: "", options: .regularExpression)
        return kept.joined(separator: "\n")
    }

    private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Paths of the machine the goal was written on mean nothing to a reader and say who and where.
    static func scrub(_ text: String) -> String {
        let roots = "Users|home|private|var|tmp|Volumes|opt|etc|root|Library"
        let patterns = [
            // Any absolute path of two or more segments; `(?<!:/)` keeps the path of an http(s) URL whole.
            "(?<![\\w.-])(?<!:/)/[^\\s/)\\]>`'\"]+(?:/[^\\s)\\]>`'\"]*)+",
            "(?<![\\w.-])/(?:\(roots))/[^\\s)\\]>`'\"]*",
            "(?<![\\w.-])~/[^\\s)\\]>`'\"]*",
            "(?<![\\w-])\\.workbench/[^\\s)\\]>`'\"]*",
        ]
        return patterns.reduce(text) {
            $0.replacingOccurrences(of: $1, with: "<path>", options: .regularExpression)
        }
    }
}
