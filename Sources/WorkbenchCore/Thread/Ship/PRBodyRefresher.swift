import Foundation

/// A pull request's title and body as GitHub holds them.
public struct PRText: Sendable, Equatable {
    public var title: String
    public var body: String
}

/// A proposal to change an existing pull request: a new title and the new content of some of its sections.
public struct PRRefresh: Sendable, Equatable {
    public var title: String
    /// Lower-cased heading name to the section's new content, without its heading line.
    public var sections: [String: String]
}

public enum PRRefreshError: Error, Equatable, Sendable, CustomStringConvertible {
    case unknownSection(String)
    case ambiguousSection(String)
    case emptySection(String)
    case headingInContent(String)
    case blockInContent(String)
    case tooLong(String)
    case notEditable(String)

    public var description: String {
        switch self {
        case .unknownSection(let name): "the pull request has no section named '\(name)'"
        case .ambiguousSection(let name): "the pull request has more than one section named '\(name)'"
        case .emptySection(let name): "the new text for '\(name)' is empty"
        case .headingInContent(let name): "the new text for '\(name)' contains a heading of its own"
        case .blockInContent(let name): "the new text for '\(name)' contains a bot block (<!-- NAME --> ... <!-- /NAME -->)"
        case .tooLong(let name): "the new text for '\(name)' is longer than \(PRBodyRefresher.sectionLimit) characters"
        case .notEditable(let name):
            "'\(name)' has a bot block that is not at its end, or a heading of its own, so it is left for a person"
        }
    }
}

/// Edits an existing pull request body without touching what it does not own. Pure: no git, no files.
///
/// A body is split into sections at its headings (fenced code is skipped). Only the sections a proposal
/// names are replaced; every other line stays byte for byte, line endings included. A block that a tool
/// wrote between `<!-- NAME -->` and `<!-- /NAME -->` (a review bot's summary, for one) is never shown to
/// the model and is kept in place. A section is only offered for editing when it is safe to rewrite whole:
/// its bot blocks all sit at its end on lines of their own, and it holds no heading of its own in any
/// Markdown form (indented, or underlined with `===` or `---`).
public enum PRBodyRefresher {
    public static let sectionLimit = 20_000

    /// A section a proposal may replace.
    public struct Editable: Sendable, Equatable {
        /// Lower-cased heading text, the key a proposal uses.
        public var name: String
        /// The heading as written, for display.
        public var heading: String
        /// What the section says now, without bot blocks and with `\n` line endings.
        public var content: String
    }

    // MARK: Reading

    public static func editable(in body: String) -> [Editable] {
        guard !body.contains(tokenPrefix) else { return [] }
        let masked = mask(body).text
        return parts(of: masked).compactMap { part in
            guard let heading = part.heading, let name = headingName(of: heading), isEditable(part.lines) else { return nil }
            return Editable(name: name, heading: stripCR(heading), content: visible(part.lines))
        }
    }

    // MARK: Applying

    /// The body with each named section replaced. Throws before changing anything when a name is unknown,
    /// ambiguous or not editable, or a new text is empty, too long, carries a heading of its own, or carries
    /// a bot block. A proposal that names no section returns the body itself.
    public static func apply(_ refresh: PRRefresh, to body: String) throws -> String {
        if refresh.sections.isEmpty { return body }
        // The placeholders could be confused with text that happens to look like one.
        if body.contains(tokenPrefix), let name = refresh.sections.keys.min() { throw PRRefreshError.notEditable(name) }
        let crlf = body.contains("\r\n")
        let (masked, blocks) = mask(body)
        var all = parts(of: masked)

        for (name, text) in refresh.sections.sorted(by: { $0.key < $1.key }) {
            let matches = all.indices.filter { all[$0].heading.flatMap(headingName(of:)) == name }
            guard !matches.isEmpty else { throw PRRefreshError.unknownSection(name) }
            guard matches.count == 1, let index = matches.first else { throw PRRefreshError.ambiguousSection(name) }
            guard isEditable(all[index].lines) else { throw PRRefreshError.notEditable(name) }

            let content = text.replacingOccurrences(of: "\r\n", with: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { throw PRRefreshError.emptySection(name) }
            guard content.count <= sectionLimit else { throw PRRefreshError.tooLong(name) }
            guard mask(content).blocks.isEmpty, !content.contains(tokenPrefix) else { throw PRRefreshError.blockInContent(name) }
            let inner = parts(of: content)
            guard inner.count == 1, inner[0].heading == nil, !hasHeading(inner[0].lines) else {
                throw PRRefreshError.headingInContent(name)
            }

            let old = all[index].lines
            let leading = Array(old.prefix { isBlank($0) })
            let trailing = old.count > leading.count ? Array(old.reversed().prefix { isBlank($0) }.reversed()) : []
            let blank = crlf ? "\r" : ""
            var lines = leading + content.split(separator: "\n", omittingEmptySubsequences: false).map {
                crlf ? $0 + "\r" : String($0)
            }
            for line in old where blockToken(line) != nil { lines += [blank, line] }
            all[index].lines = lines + trailing
        }
        var result = unmask(render(all), blocks: blocks)
        // The last line of a body has no line ending, so an edit that ends the body must not add one.
        if crlf, result.hasSuffix("\r"), !body.hasSuffix("\r") { result.removeLast() }
        return result
    }

    // MARK: Sections

    struct Part {
        var heading: String?
        var lines: [String] = []
    }

    /// Splits at ATX headings. Lines keep their own `\r`, so joining them again gives the original bytes.
    static func parts(of text: String) -> [Part] {
        var result = [Part()]
        var fence: (char: Character, length: Int)?
        // `\r\n` is one Character in Swift, so a Character split on `\n` would never split a CRLF body.
        for line in text.components(separatedBy: "\n") {
            let plain = stripCR(line)
            let wasFenced = fence != nil
            fence = PRBodyBuilder.nextFence(after: fence, line: plain)
            let fenced = wasFenced || fence != nil
            if !fenced, plain.hasPrefix("#"), PRBodyBuilder.headingName(plain) != nil {
                result.append(Part(heading: line))
            } else {
                result[result.count - 1].lines.append(line)
            }
        }
        return result
    }

    private static func headingName(of heading: String) -> String? { PRBodyBuilder.headingName(stripCR(heading)) }

    private static func render(_ parts: [Part]) -> String {
        var lines: [String] = []
        for part in parts {
            if let heading = part.heading { lines.append(heading) }
            lines += part.lines
        }
        return lines.joined(separator: "\n")
    }

    private static func stripCR(_ line: String) -> String { line.hasSuffix("\r") ? String(line.dropLast()) : line }

    private static func isBlank(_ line: String) -> Bool { line.allSatisfy(\.isWhitespace) }

    private static func visible(_ lines: [String]) -> String {
        let kept = lines.filter { blockToken($0) == nil }.map(stripCR)
        guard let first = kept.firstIndex(where: { !isBlank($0) }),
            let last = kept.lastIndex(where: { !isBlank($0) })
        else { return "" }
        return kept[first...last].joined(separator: "\n")
    }

    /// Whether the section can be rewritten whole without losing or moving anything that is not text.
    private static func isEditable(_ lines: [String]) -> Bool {
        let tokenLines = lines.indices.filter { blockToken(lines[$0]) != nil }
        let mentions = lines.reduce(0) { $0 + $1.components(separatedBy: tokenPrefix).count - 1 }
        guard mentions == tokenLines.count else { return false }
        if let firstToken = tokenLines.first,
            lines[firstToken...].contains(where: { blockToken($0) == nil && !isBlank($0) }) {
            return false
        }
        return !hasHeading(lines.filter { blockToken($0) == nil })
    }

    /// A heading in any Markdown form outside fenced code: `#` up to three spaces in, or a text line
    /// underlined with `=` or `-`.
    static func hasHeading(_ lines: [String]) -> Bool {
        var fence: (char: Character, length: Int)?
        var previousText = false
        for raw in lines {
            let line = stripCR(raw)
            let wasFenced = fence != nil
            fence = PRBodyBuilder.nextFence(after: fence, line: line)
            if wasFenced || fence != nil {
                previousText = false
                continue
            }
            if line.range(of: #"^ {0,3}#{1,6}([ \t]|$)"#, options: .regularExpression) != nil { return true }
            if previousText, line.range(of: #"^ {0,3}(=+|-+)[ \t]*$"#, options: .regularExpression) != nil { return true }
            previousText = !isBlank(line)
        }
        return false
    }

    // MARK: Bot blocks

    private static let blockPattern = #"<!--[ \t]*([A-Za-z0-9_.-]+)[ \t]*-->[\s\S]*?<!--[ \t]*/\1[ \t]*-->"#
    private static let tokenPrefix = "<!--wb-block-"

    private static func token(_ index: Int) -> String { "\(tokenPrefix)\(index)-->" }

    private static func blockToken(_ line: String) -> Int? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(tokenPrefix), trimmed.hasSuffix("-->") else { return nil }
        return Int(trimmed.dropFirst(tokenPrefix.count).dropLast(3))
    }

    /// Replaces every bot block with a one-line token, so no heading-like line inside one splits a section.
    static func mask(_ text: String) -> (text: String, blocks: [String]) {
        guard let regex = try? NSRegularExpression(pattern: blockPattern) else { return (text, []) }
        let source = text as NSString
        var blocks: [String] = []
        var out = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            out += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            out += token(blocks.count)
            blocks.append(source.substring(with: match.range))
            cursor = match.range.location + match.range.length
        }
        out += source.substring(from: cursor)
        return (out, blocks)
    }

    private static func unmask(_ text: String, blocks: [String]) -> String {
        var result = text
        for (index, block) in blocks.enumerated() {
            result = result.replacingOccurrences(of: token(index), with: block)
        }
        return result
    }
}
