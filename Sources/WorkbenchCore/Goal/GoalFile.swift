import Foundation

/// A parsed `goal.md`: the goal plus enough of the original text to rewrite the front matter without
/// disturbing the body or the author's comments.
public struct GoalFile: Sendable, Equatable {
    public let goal: Goal
    public let text: String

    private let frontMatter: [FrontMatterLine]
    private let bodyStartLine: Int

    // MARK: Parsing

    public static func parse(_ text: String) throws -> GoalFile {
        var problems: [GoalProblem] = []
        func add(_ code: GoalProblem.Code, _ line: Int?, _ message: String) {
            problems.append(GoalProblem(code: code, line: line, message: message))
        }

        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        let (entries, closing) = try frontMatter(lines, add: add)
        func value(_ key: String) -> FrontMatterLine? { entries.first { $0.key == key } }

        func required(_ key: String) -> String? {
            guard let entry = value(key) else {
                add(.missingKey, nil, "missing required key '\(key)'")
                return nil
            }
            guard !entry.value.isEmpty else {
                add(.invalidValue, entry.lineNumber, "'\(key)' must not be empty")
                return nil
            }
            return entry.value
        }

        let id = required("id").flatMap { id -> String? in
            guard let entry = value("id") else { return nil }
            guard SafeNames.isThreadID(id) else {
                add(
                    .invalidValue, entry.lineNumber,
                    "'id' is used as a directory name: letters, digits, '.', '_' and '-' only, up to 100")
                return nil
            }
            return id
        }
        let title = required("title")
        let base = required("base").flatMap { base -> String? in
            guard let entry = value("base") else { return nil }
            guard SafeNames.isBranchName(base) else {
                add(.invalidValue, entry.lineNumber, "'base' is not a safe branch name: '\(base)'")
                return nil
            }
            return base
        }
        let budget = required("budget_usd").flatMap { raw -> Decimal? in
            guard let entry = value("budget_usd") else { return nil }
            guard let d = budgetValue(raw) else {
                add(.invalidValue, entry.lineNumber, budgetProblem(raw))
                return nil
            }
            return d
        }
        let timeout = required("turn_timeout_min").flatMap { raw -> Int? in
            guard let entry = value("turn_timeout_min") else { return nil }
            guard let n = timeoutValue(raw) else {
                add(.invalidValue, entry.lineNumber, timeoutProblem(raw))
                return nil
            }
            return n
        }
        let model = modelValue(value("model"), add: add)
        let pushTo = pushToValue(value("push_to"), add: add)
        if let pushTo, let base, let entry = value("base"), base != "origin/\(pushTo)" {
            add(.invalidValue, entry.lineNumber, "'base' must be 'origin/\(pushTo)' when 'push_to' is set, found '\(base)'")
        }
        var declared = GoalStatus.draft
        if let entry = value("status") {
            if let status = GoalStatus(rawValue: entry.value) {
                declared = status
            } else {
                add(.invalidValue, entry.lineNumber, "'status' must be 'draft' or 'approved', found '\(entry.value)'")
            }
        }

        let bodyStart = closing + 1
        let parsed = parseBody(lines, from: bodyStart, add: add)
        let (request, criteria, outOfScope) = (parsed.request, parsed.criteria, parsed.outOfScope)

        guard problems.isEmpty, let id, let title, let base, let budget, let timeout else {
            throw GoalParseError(problems: problems.sorted { ($0.line ?? .max) < ($1.line ?? .max) })
        }

        let body = lines[bodyStart...].joined(separator: "\n")
        let goal = Goal(
            id: id, title: title, declaredStatus: declared, base: base, budgetUSD: budget,
            turnTimeoutMin: timeout, model: model, pushTo: pushTo, approvedAt: value("approved_at")?.value,
            approvedHash: value("approved_hash")?.value, request: request, criteria: criteria,
            outOfScope: outOfScope,
            contentHash: GoalHash.hash(
                base: base, budgetUSD: budget, turnTimeoutMin: timeout, model: model, pushTo: pushTo, body: body))
        return GoalFile(goal: goal, text: normalized, frontMatter: entries, bodyStartLine: bodyStart)
    }

    /// The front matter block's entries and the index of its closing `---`. Unknown, duplicate and malformed
    /// lines are reported through `add`; a file without the block throws.
    static func frontMatter(
        _ lines: [String], add: (GoalProblem.Code, Int?, String) -> Void
    ) throws -> (entries: [FrontMatterLine], closing: Int) {
        guard lines.first == "---" else {
            throw GoalParseError(problems: [
                GoalProblem(
                    code: .missingFrontMatter, line: 1,
                    message: "goal must start with a front matter block delimited by '---'")
            ])
        }
        guard let closing = lines.indices.dropFirst().first(where: { lines[$0] == "---" }) else {
            throw GoalParseError(problems: [
                GoalProblem(
                    code: .unterminatedFrontMatter, line: 1,
                    message: "front matter has no closing '---'")
            ])
        }
        var entries: [FrontMatterLine] = []
        var seen = Set<String>()
        for index in 1..<closing {
            let number = index + 1
            let raw = lines[index]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let entry = FrontMatterLine(raw: raw, lineNumber: number) else {
                add(.malformedFrontMatterLine, number, "expected 'key: value', found '\(trimmed)'")
                continue
            }
            if !FrontMatterLine.knownKeys.contains(entry.key) {
                add(.unknownKey, number, "unknown key '\(entry.key)'")
            } else if !seen.insert(entry.key).inserted {
                add(.duplicateKey, number, "key '\(entry.key)' appears more than once")
            }
            entries.append(entry)
        }
        return (entries, closing)
    }

    struct Body {
        var request: String
        var criteria: [Criterion]
        var outOfScope: [String]
    }

    /// The request, criteria and out of scope of the lines from `bodyStart` on.
    static func parseBody(
        _ lines: [String], from bodyStart: Int, add: (GoalProblem.Code, Int?, String) -> Void
    ) -> Body {
        var malformedCriterion = false
        func note(_ code: GoalProblem.Code, _ line: Int?, _ message: String) {
            if code == .malformedCriterion { malformedCriterion = true }
            add(code, line, message)
        }
        let sections = parseSections(Array(lines[bodyStart...]), firstLine: bodyStart + 1, add: note)

        var request = ""
        if let section = sections["request"] {
            request = section.lines.map(\.text).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if request.isEmpty { note(.emptySection, section.headingLine, "'## Request' is empty") }
        } else {
            note(.missingSection, nil, "missing '## Request' section")
        }

        var criteria: [Criterion] = []
        if let section = sections["criteria"] {
            criteria = parseCriteria(section, add: note)
            if criteria.isEmpty && !malformedCriterion {
                note(.emptySection, section.headingLine, "'## Criteria' has no criteria")
            }
        } else {
            note(.missingSection, nil, "missing '## Criteria' section")
        }

        let outOfScope = sections["out of scope"].map { parseOutOfScope($0, add: note) } ?? []
        return Body(request: request, criteria: criteria, outOfScope: outOfScope)
    }

    static func budgetValue(_ raw: String) -> Decimal? {
        guard let d = Decimal(string: raw), d > 0,
            raw.range(of: #"^[0-9]+(\.[0-9]+)?$"#, options: .regularExpression) != nil
        else { return nil }
        return d
    }

    static func budgetProblem(_ raw: String) -> String { "'budget_usd' must be a positive number, found '\(raw)'" }

    static func timeoutValue(_ raw: String) -> Int? {
        guard let n = Int(raw), (1...1440).contains(n) else { return nil }
        return n
    }

    static func timeoutProblem(_ raw: String) -> String {
        "'turn_timeout_min' must be a whole number from 1 to 1440, found '\(raw)'"
    }

    static func modelProblem(_ raw: String) -> String {
        "'model' must be a model name or alias like \"opus\", found '\(raw)'"
    }

    private static func modelValue(
        _ entry: FrontMatterLine?, add: (GoalProblem.Code, Int?, String) -> Void
    ) -> String? {
        guard let entry else { return nil }
        guard SafeNames.isModelName(entry.value) else {
            add(.invalidValue, entry.lineNumber, modelProblem(entry.value))
            return nil
        }
        return entry.value
    }

    private static func pushToValue(
        _ entry: FrontMatterLine?, add: (GoalProblem.Code, Int?, String) -> Void
    ) -> String? {
        guard let entry else { return nil }
        guard SafeNames.isPushTarget(entry.value) else {
            add(
                .invalidValue, entry.lineNumber,
                "'push_to' must be a safe branch name that is not main, master, trunk or develop, found '\(entry.value)'")
            return nil
        }
        return entry.value
    }

    // MARK: Approval

    /// Returns the file text with `status`, `approved_at` and `approved_hash` set for the current content.
    /// Everything else, comments included, is kept as written. Already-approved goals are returned as is.
    public func approving(at date: Date = Date()) throws -> GoalFile {
        if goal.approval == .approved { return self }
        let stamp = Date.ISO8601FormatStyle().format(date)
        var updated = frontMatter
        func set(_ key: String, _ value: String) {
            if let i = updated.firstIndex(where: { $0.key == key }) {
                updated[i].value = value
            } else {
                updated.append(FrontMatterLine(key: key, value: value))
            }
        }
        set("status", GoalStatus.approved.rawValue)
        set("approved_at", stamp)
        set("approved_hash", goal.contentHash)

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let body = lines[bodyStartLine...].joined(separator: "\n")
        let newText = (["---"] + updated.map(\.rendered) + ["---"]).joined(separator: "\n") + "\n" + body
        return try GoalFile.parse(newText)
    }

    // MARK: Sections

    private struct Section {
        var headingLine: Int
        var lines: [(number: Int, text: String)] = []
    }

    private static func parseSections(
        _ lines: [String], firstLine: Int,
        add: (GoalProblem.Code, Int?, String) -> Void
    ) -> [String: Section] {
        var sections: [String: Section] = [:]
        var current: String?
        for (offset, text) in lines.enumerated() {
            let number = firstLine + offset
            if text.hasPrefix("## ") {
                let name = String(text.dropFirst(3)).trimmingCharacters(in: .whitespaces).lowercased()
                if sections[name] != nil {
                    add(.duplicateSection, number, "section '## \(text.dropFirst(3))' appears more than once")
                    current = nil
                } else {
                    sections[name] = Section(headingLine: number)
                    current = name
                }
            } else if let key = current {
                sections[key]?.lines.append((number, text))
            }
        }
        return sections
    }

    private static func parseOutOfScope(
        _ section: Section, add: (GoalProblem.Code, Int?, String) -> Void
    ) -> [String] {
        var bullets: [String] = []
        for line in section.lines {
            let trimmed = line.text.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("- ") {
                bullets.append(String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces))
            } else if !bullets.isEmpty, line.text.first == " " || line.text.first == "\t" {
                // An indented line wraps the bullet above it, as it does in a criterion.
                bullets[bullets.count - 1] += " " + trimmed
            } else {
                add(.unrecognizedLine, line.number, "expected a '- ' bullet in 'Out of scope', found '\(trimmed)'")
            }
        }
        return bullets
    }

    private static func parseCriteria(
        _ section: Section, add: (GoalProblem.Code, Int?, String) -> Void
    ) -> [Criterion] {
        struct Pending { var id: String; var text: String; var proof: String?; var line: Int }
        var done: [Criterion] = []
        var pending: Pending?
        var ids = Set<String>()

        func finish() {
            guard let p = pending else { return }
            if let proof = p.proof, !proof.isEmpty {
                if ScreenshotProof.isMalformed(proof) {
                    add(
                        .malformedScreenshotProof, p.line,
                        "criterion [\(p.id)]: a screenshot proof is 'screenshot: <name>' (or several, separated by commas, "
                            + "at most \(ScreenshotProof.maxNames)) with names of letters, digits, '.', '_' or '-' "
                            + "(the file is <name>.png)")
                }
                done.append(Criterion(id: p.id, text: p.text, proof: proof))
            } else {
                add(.criterionWithoutProof, p.line, "criterion [\(p.id)] has no '- proof:' line")
            }
            pending = nil
        }

        for (number, text) in section.lines {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            let indented = text.hasPrefix(" ") || text.hasPrefix("\t")

            if !indented, trimmed.hasPrefix("- ") {
                finish()
                guard let match = trimmed.wholeMatch(of: #/- \[(c[0-9]+)\]\s+(.+)/#) else {
                    add(.malformedCriterion, number, "expected '- [c1] text', found '\(trimmed)'")
                    continue
                }
                let id = String(match.1)
                if !ids.insert(id).inserted {
                    add(.duplicateCriterionID, number, "criterion id [\(id)] is used more than once")
                }
                pending = Pending(id: id, text: String(match.2), proof: nil, line: number)
            } else if indented, let p = pending {
                if let match = trimmed.wholeMatch(of: #/- proof:\s*(.*)/#) {
                    pending?.proof = String(match.1)
                } else if trimmed.hasPrefix("- ") {
                    add(.unrecognizedLine, number, "expected '- proof: ...' under [\(p.id)], found '\(trimmed)'")
                } else if pending?.proof == nil {
                    pending?.text += " " + trimmed
                } else {
                    pending?.proof? += " " + trimmed
                }
            } else {
                add(.unrecognizedLine, number, "unexpected text in 'Criteria': '\(trimmed)'")
            }
        }
        finish()
        return done
    }
}

/// One `key: value  # comment` line of the front matter.
struct FrontMatterLine: Sendable, Equatable {
    static let knownKeys: Set<String> = [
        "id", "title", "status", "base", "budget_usd", "turn_timeout_min", "model", "push_to", "approved_at",
        "approved_hash",
    ]

    var key: String
    var value: String
    var comment: String?
    var lineNumber = 0

    init(key: String, value: String, comment: String? = nil) {
        self.key = key
        self.value = value
        self.comment = comment
    }

    /// Comments start at `#` preceded by two or more spaces, so `title: Fix #12` stays intact. Quote a
    /// value that needs ` #` after two spaces.
    init?(raw: String, lineNumber: Int) {
        guard let match = raw.wholeMatch(of: #/([A-Za-z_][A-Za-z0-9_]*):\s*(.*)/#) else { return nil }
        key = String(match.1)
        self.lineNumber = lineNumber
        var rest = String(match.2)
        comment = nil

        if let first = rest.first, first == "\"" || first == "'",
            let close = rest.dropFirst().firstIndex(of: first) {
            let inner = rest[rest.index(after: rest.startIndex)..<close]
            let after = rest[rest.index(after: close)...].trimmingCharacters(in: .whitespaces)
            if after.hasPrefix("#") {
                comment = String(after.dropFirst()).trimmingCharacters(in: .whitespaces)
            } else if !after.isEmpty {
                return nil
            }
            value = String(inner)
            return
        }

        if let range = rest.range(of: #"\s{2,}#"#, options: .regularExpression) {
            comment = String(rest[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            rest = String(rest[..<range.lowerBound])
        }
        value = rest.trimmingCharacters(in: .whitespaces)
    }

    var rendered: String {
        let needsQuotes = value.contains("  #") || value.hasPrefix("\"") || value.hasPrefix("'")
        let shown = needsQuotes ? "\"\(value)\"" : value
        return "\(key): \(shown)" + (comment.map { "  # \($0)" } ?? "")
    }
}
