import Foundation

/// One change to a goal file. Each is applied on its own, to the file as it is, so the parts the editor does not model
/// (comments, other front matter, sections it does not know) stay as written.
public enum GoalEdit: Sendable, Equatable {
    case setTitle(String)
    case setRequest(String)
    case addCriterion(text: String, proof: String)
    /// A nil field is kept as it is.
    case updateCriterion(id: String, text: String?, proof: String?)
    case removeCriterion(id: String)
    /// `to` is the position the criterion ends up at, from 0.
    case moveCriterion(id: String, to: Int)
    case setOutOfScope([String])
    /// Steps this goal turns off: `verifier`, `judge` or a stage's name. Empty clears the key.
    case setSkip([String])
    /// Folders this goal's runs may read besides the config's. Empty clears the key.
    case setReadAlso([String])
}

/// Why an edit was refused. Nothing is written in that case.
public struct GoalEditError: Error, CustomStringConvertible, Equatable {
    public var reason: String
    public var description: String { reason }
}

/// Applies a `GoalEdit` to the text of a goal file, as a pure function: the caller reads and writes the file.
public enum GoalEditor {
    public static func apply(_ edit: GoalEdit, to file: GoalFile) throws -> GoalFile {
        var lines = file.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let goal = file.goal
        let expected: (Goal) -> Bool

        switch edit {
        case .setTitle(let title):
            let title = try singleLine(title, "the title")
            try setFrontMatter("title", title, in: &lines, file: file)
            expected = { $0.title == title }

        case .setRequest(let request):
            let text = request.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw GoalEditError(reason: "the request cannot be empty") }
            let requestLines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if let heading = requestLines.first(where: { $0.hasPrefix("## ") }) {
                throw GoalEditError(reason: "a line of the request starts a section ('\(heading)'); indent it or reword it")
            }
            try replaceSection("request", with: [""] + requestLines + [""], in: &lines, file: file)
            expected = { $0.request == text }

        case .addCriterion(let text, let proof):
            let text = try singleLine(text, "a criterion's text"), proof = try singleLine(proof, "a criterion's proof")
            // The next free number, never a gap filled: the log and the judge refer to ids.
            let highest = goal.criteria.compactMap { Int($0.id.dropFirst()) }.max() ?? 0
            let (next, overflow) = highest.addingReportingOverflow(1)
            guard !overflow else { throw GoalEditError(reason: "no criterion number is free after the highest") }
            let id = "c\(next)"
            var layout = try criterionBlocks(lines, file: file)
            layout.blocks.append(CriterionBlock(id: id, lines: block(id, text, proof)))
            try writeCriteria(layout, in: &lines, file: file)
            expected = { $0.criteria.map(\.id) == goal.criteria.map(\.id) + [id] && $0.criteria.last?.text == text }

        case .updateCriterion(let id, let text, let proof):
            guard let current = goal.criteria.first(where: { $0.id == id }) else { throw unknown(id) }
            let newText = try text.map { try singleLine($0, "a criterion's text") } ?? current.text
            let newProof = try proof.map { try singleLine($0, "a criterion's proof") } ?? current.proof
            var layout = try criterionBlocks(lines, file: file)
            guard let index = layout.blocks.firstIndex(where: { $0.id == id }) else { throw unknown(id) }
            layout.blocks[index].lines = rewritten(layout.blocks[index].lines, text: newText, proof: newProof, current: current)
            try writeCriteria(layout, in: &lines, file: file)
            expected = { $0.criteria.first { $0.id == id }.map { $0.text == newText && $0.proof == newProof } == true }

        case .removeCriterion(let id):
            guard goal.criteria.contains(where: { $0.id == id }) else { throw unknown(id) }
            guard goal.criteria.count > 1 else { throw GoalEditError(reason: "a goal needs at least one criterion") }
            var layout = try criterionBlocks(lines, file: file)
            layout.blocks.removeAll { $0.id == id }
            try writeCriteria(layout, in: &lines, file: file)
            expected = { $0.criteria.map(\.id) == goal.criteria.map(\.id).filter { $0 != id } }

        case .moveCriterion(let id, let position):
            guard goal.criteria.contains(where: { $0.id == id }) else { throw unknown(id) }
            guard (0..<goal.criteria.count).contains(position) else {
                throw GoalEditError(reason: "there is no position \(position): the goal has \(goal.criteria.count) criteria")
            }
            var layout = try criterionBlocks(lines, file: file)
            guard let from = layout.blocks.firstIndex(where: { $0.id == id }) else { throw unknown(id) }
            layout.blocks.insert(layout.blocks.remove(at: from), at: position)
            try writeCriteria(layout, in: &lines, file: file)
            let order = layout.blocks.map(\.id)
            expected = { $0.criteria.map(\.id) == order }

        case .setOutOfScope(let items):
            let items = try items.map { try singleLine($0, "an out-of-scope item") }
            let body = [""] + items.map { "- \($0)" } + [""]
            if sectionRange("out of scope", in: lines, file: file) != nil {
                try replaceSection("out of scope", with: body, in: &lines, file: file)
            } else {
                while lines.last?.isEmpty == true { lines.removeLast() }
                lines += ["", "## Out of scope"] + body
            }
            expected = { $0.outOfScope == items }

        case .setSkip(let steps):
            try setFrontMatter("skip", steps.isEmpty ? nil : steps.joined(separator: ", "), in: &lines, file: file)
            expected = { $0.skip == steps }

        case .setReadAlso(let folders):
            try setFrontMatter("read_also", folders.isEmpty ? nil : folders.joined(separator: ", "), in: &lines, file: file)
            expected = { $0.readAlso == folders }
        }

        let edited: GoalFile
        do { edited = try GoalFile.parse(lines.joined(separator: "\n")) } catch let error as GoalParseError {
            throw GoalEditError(reason: "the edit would leave a goal that does not parse: \(error.description)")
        }
        // The edit says what it meant; if the file does not read back as that, it is refused rather than written.
        guard expected(edited.goal) else { throw GoalEditError(reason: "the edit would not read back as written") }
        return edited
    }

    // MARK: Pieces

    /// A criterion's own lines, and the blank lines that followed it in the file (`gap`).
    private struct CriterionBlock {
        var id: String
        var lines: [String]
        var gap: [String] = []
    }

    /// What the criteria section holds besides the criteria: the blank lines before the first and after the last.
    private struct CriteriaLayout {
        var blocks: [CriterionBlock]
        var head: [String]
        var tail: [String]
    }

    private static func unknown(_ id: String) -> GoalEditError { GoalEditError(reason: "the goal has no criterion [\(id)]") }

    private static func singleLine(_ text: String, _ what: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw GoalEditError(reason: "\(what) cannot be empty") }
        guard !trimmed.contains(where: \.isNewline) else { throw GoalEditError(reason: "\(what) must be one line") }
        return trimmed
    }

    /// A criterion with new text or proof. What did not change stays as written: nothing changed keeps every line (wrapping
    /// included), only the proof changed keeps the text's lines.
    private static func rewritten(_ lines: [String], text: String, proof: String, current: Criterion) -> [String] {
        if text == current.text && proof == current.proof { return lines }
        let proofLine = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("- proof:") }
        if text == current.text, let at = proofLine { return Array(lines[..<at]) + ["  - proof: \(proof)"] }
        return block(current.id, text, proof)
    }

    private static func block(_ id: String, _ text: String, _ proof: String) -> [String] {
        ["- [\(id)] \(text)", "  - proof: \(proof)"]
    }

    /// The lines of `## <name>` after its heading, up to the next heading (or the end of the file).
    private static func sectionRange(_ name: String, in lines: [String], file: GoalFile) -> Range<Int>? {
        guard
            let heading = lines.indices.dropFirst(file.bodyStartLine).first(where: {
                lines[$0].hasPrefix("## ") && lines[$0].dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased() == name
            })
        else { return nil }
        let end = lines.indices.dropFirst(heading + 1).first { lines[$0].hasPrefix("## ") } ?? lines.count
        return (heading + 1)..<end
    }

    private static func replaceSection(_ name: String, with body: [String], in lines: inout [String], file: GoalFile) throws {
        guard let range = sectionRange(name, in: lines, file: file) else {
            throw GoalEditError(reason: "the goal has no '## \(name)' section")
        }
        lines.replaceSubrange(range, with: body)
    }

    /// The criteria as the file has them: a criterion's line and everything indented under it, with the spacing around them,
    /// so an edit that changes nothing writes the same bytes (blank lines are part of the hash).
    private static func criterionBlocks(_ lines: [String], file: GoalFile) throws -> CriteriaLayout {
        guard let range = sectionRange("criteria", in: lines, file: file) else {
            throw GoalEditError(reason: "the goal has no '## Criteria' section")
        }
        var layout = CriteriaLayout(blocks: [], head: [], tail: [])
        for index in range {
            let line = lines[index]
            if let match = line.wholeMatch(of: #/- \[(c[0-9]+)\]\s+(.+)/#) {
                layout.blocks.append(CriterionBlock(id: String(match.1), lines: [line]))
            } else if layout.blocks.isEmpty {
                layout.head.append(line)
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                layout.blocks[layout.blocks.count - 1].gap.append(line)
            } else if let last = layout.blocks.indices.last, layout.blocks[last].gap.isEmpty {
                layout.blocks[last].lines.append(line)
            } else {
                // Text after a blank line is not part of a criterion the editor knows; the parse would have refused it.
                throw GoalEditError(reason: "the criteria section holds text the editor cannot place: '\(line)'")
            }
        }
        if let last = layout.blocks.indices.last {
            layout.tail = layout.blocks[last].gap
            layout.blocks[last].gap = []
        }
        return layout
    }

    /// The blocks in their new order. A block between others keeps its own gap, or takes the one the file already uses.
    private static func writeCriteria(_ layout: CriteriaLayout, in lines: inout [String], file: GoalFile) throws {
        let usual = layout.blocks.first { !$0.gap.isEmpty }?.gap ?? []
        var body = layout.head
        for (index, block) in layout.blocks.enumerated() {
            body += block.lines
            if index < layout.blocks.count - 1 { body += block.gap.isEmpty ? usual : block.gap }
        }
        body += layout.tail
        try replaceSection("criteria", with: body, in: &lines, file: file)
    }

    /// Sets (or, with nil, removes) one front matter line, keeping its comment and every other line as written.
    private static func setFrontMatter(_ key: String, _ value: String?, in lines: inout [String], file: GoalFile) throws {
        if let value, !FrontMatterLine.canRender(value) {
            throw GoalEditError(reason: "'\(key)' holds both kinds of quote and a comment marker; reword it")
        }
        if let entry = file.frontMatter.first(where: { $0.key == key }) {
            let index = entry.lineNumber - 1
            if let value {
                lines[index] = FrontMatterLine(key: key, value: value, comment: entry.comment).rendered
            } else {
                lines.remove(at: index)
            }
        } else if let value {
            // Before the closing `---`.
            lines.insert(FrontMatterLine(key: key, value: value).rendered, at: file.bodyStartLine - 1)
        }
    }
}
