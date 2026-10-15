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

    public var description: String {
        switch self {
        case .unknownSection(let name): "the pull request has no section named '\(name)'"
        case .ambiguousSection(let name): "the pull request has more than one section named '\(name)'"
        case .emptySection(let name): "the new text for '\(name)' is empty"
        case .headingInContent(let name): "the new text for '\(name)' contains a heading of its own"
        case .blockInContent(let name): "the new text for '\(name)' contains a bot block (<!-- NAME --> ... <!-- /NAME -->)"
        case .tooLong(let name): "the new text for '\(name)' is longer than \(PRBodyRefresher.sectionLimit) characters"
        }
    }
}

/// Edits an existing pull request body without touching what it does not own. Pure: no git, no files.
///
/// A body is split into sections at its headings (fenced code is skipped). Only the sections a proposal
/// names are replaced; every other line stays byte for byte. A block that a tool wrote between
/// `<!-- NAME -->` and `<!-- /NAME -->` (a review bot's summary, for one) is never shown to the model and
/// is kept in place, wherever it sits.
public enum PRBodyRefresher {
    public static let sectionLimit = 20_000

    /// A section a proposal may replace.
    public struct Editable: Sendable, Equatable {
        /// Lower-cased heading text, the key a proposal uses.
        public var name: String
        /// The heading as written, for display.
        public var heading: String
        /// What the section says now, without bot blocks.
        public var content: String
    }

    // MARK: Reading

    public static func editable(in body: String) -> [Editable] {
        let masked = mask(body).text
        return parts(of: masked).compactMap { part in
            guard let heading = part.heading, let name = PRBodyBuilder.headingName(heading) else { return nil }
            return Editable(
                name: name, heading: heading, content: visible(part.lines))
        }
    }

    // MARK: Applying

    /// The body with each named section replaced. Throws before changing anything when a name is unknown or
    /// ambiguous, or a new text is empty, too long, carries a heading of its own, or carries a bot block.
    public static func apply(_ refresh: PRRefresh, to body: String) throws -> String {
        let (masked, blocks) = mask(body)
        var all = parts(of: masked)

        for (name, text) in refresh.sections.sorted(by: { $0.key < $1.key }) {
            let matches = all.indices.filter { all[$0].heading.flatMap(PRBodyBuilder.headingName) == name }
            guard !matches.isEmpty else { throw PRRefreshError.unknownSection(name) }
            guard matches.count == 1, let index = matches.first else { throw PRRefreshError.ambiguousSection(name) }

            let content = text.replacingOccurrences(of: "\r\n", with: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { throw PRRefreshError.emptySection(name) }
            guard content.count <= sectionLimit else { throw PRRefreshError.tooLong(name) }
            guard mask(content).blocks.isEmpty else { throw PRRefreshError.blockInContent(name) }
            let inner = parts(of: content)
            guard inner.count == 1, inner[0].heading == nil else { throw PRRefreshError.headingInContent(name) }

            let old = all[index].lines
            let leading = old.prefix { isBlank($0) }.count
            let trailing = old.count > leading ? old.reversed().prefix { isBlank($0) }.count : 0
            let tokens = old.filter { blockToken($0) != nil }
            let written = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            var lines = Array(repeating: "", count: leading) + written
            for token in tokens { lines += ["", token] }
            lines += Array(repeating: "", count: trailing)
            all[index].lines = lines
        }
        return unmask(render(all), blocks: blocks)
    }

    // MARK: Sections

    struct Part {
        var heading: String?
        var lines: [String] = []
    }

    static func parts(of text: String) -> [Part] {
        var result = [Part()]
        var fence: (char: Character, length: Int)?
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for line in lines {
            let wasFenced = fence != nil
            fence = PRBodyBuilder.nextFence(after: fence, line: line)
            let fenced = wasFenced || fence != nil
            if !fenced, line.hasPrefix("#"), PRBodyBuilder.headingName(line) != nil {
                result.append(Part(heading: line))
            } else {
                result[result.count - 1].lines.append(line)
            }
        }
        return result
    }

    private static func render(_ parts: [Part]) -> String {
        var lines: [String] = []
        for part in parts {
            if let heading = part.heading { lines.append(heading) }
            lines += part.lines
        }
        return lines.joined(separator: "\n")
    }

    private static func isBlank(_ line: String) -> Bool { line.allSatisfy(\.isWhitespace) }

    private static func visible(_ lines: [String]) -> String {
        let kept = lines.filter { blockToken($0) == nil }
        guard let first = kept.firstIndex(where: { !isBlank($0) }),
            let last = kept.lastIndex(where: { !isBlank($0) })
        else { return "" }
        return kept[first...last].joined(separator: "\n")
    }

    // MARK: Bot blocks

    private static let blockPattern = #"<!--[ \t]*([A-Za-z0-9_.-]+)[ \t]*-->[\s\S]*?<!--[ \t]*/\1[ \t]*-->"#
    private static let tokenPrefix = "<!--wb-block-"

    private static func token(_ index: Int) -> String { "\(tokenPrefix)\(index)-->" }

    private static func blockToken(_ line: String) -> Int? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
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
