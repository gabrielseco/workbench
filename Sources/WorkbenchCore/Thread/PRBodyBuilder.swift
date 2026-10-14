import Foundation

/// The title and description `ship` will give the pull request.
public struct PRBody: Sendable, Equatable {
    public var title: String
    public var body: String
}

/// Builds a PR title and body from the goal and the latest check outcome. Pure: no git, no files, no log.
/// The text comes from the approved goal, never from what Claude wrote afterwards, and the check is shown
/// as pass or fail only, so its output (which may hold paths or secrets) cannot reach a page others read.
public enum PRBodyBuilder {
    public static let titleLimit = 72

    /// - Parameters:
    ///   - template: the repository's PR template text, nil when it has none.
    public static func build(goal: Goal, check: Review.Check?, template: String?) -> PRBody {
        let request = scrub(goal.request).trimmingCharacters(in: .whitespacesAndNewlines)
        let checkLine = checkLine(check)
        let criteria = criteriaList(goal.criteria)
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
        return PRBody(title: title(goal.title), body: body + "\n")
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
        var fenced = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("```") || line.hasPrefix("~~~") { fenced.toggle() }
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
            var content = section.lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// Lower-cased heading text for an ATX heading (`## Summary`), nil when the line is not one.
    private static func headingName(_ line: String) -> String? {
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

    private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Paths of the machine the goal was written on mean nothing to a reader and say who and where.
    static func scrub(_ text: String) -> String {
        let roots = "Users|home|private|var|tmp|Volumes|opt|etc|root|Library"
        let patterns = [
            "(?<![\\w.-])/(?:\(roots))/[^\\s)\\]>`'\"]*",
            "(?<![\\w.-])~/[^\\s)\\]>`'\"]*",
            "(?<![\\w-])\\.workbench/[^\\s)\\]>`'\"]*",
        ]
        return patterns.reduce(text) {
            $0.replacingOccurrences(of: $1, with: "<path>", options: .regularExpression)
        }
    }
}
