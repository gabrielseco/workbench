import Foundation

/// Everything the refresh turn is told, assembled by Workbench. The model reads nothing else.
public struct PRRefreshInput: Sendable, Equatable {
    public var goal: Goal
    public var notes: [String]
    public var turnResult: String?
    /// The commits this thread added on top of the branch.
    public var commits: [String]
    /// What this thread changed on top of the branch, not the whole pull request.
    public var diff: String
    public var diffTruncated: Bool
    public var check: Review.Check?
    public var current: PRText
}

/// The request to the refresh turn and the reading of its answer. Pure: no process, no files.
///
/// The turn edits an existing pull request: it sees the text a reviewer has already read and what this
/// thread changed since, and may return a new title and new text for the sections that change made false
/// or incomplete. It cannot add a section, touch a bot block, or write the criteria table or the check
/// line, which are reported separately.
public enum PRRefresher {
    public static func prompt(for input: PRRefreshInput) -> String {
        var parts: [String] = [
            """
            A pull request is already open and a reviewer has read it. More work was added to its branch.
            Update the pull request text only where that work makes it false or incomplete.
            You have no tools. Everything you may use is below. Reply with ONE JSON object and nothing else:
            {"title": string, "sections": {"<section name>": string}}
            - title: the current title if it is still true; otherwise Conventional Commits `type(scope): subject`,
              one line, at most \(PRBodyBuilder.titleLimit) characters.
            - sections: only the sections you change, keyed by the exact name listed below, each with its complete
              new text without the heading. Leave out every section that is still true. {} when none change.
            - Change as little as possible: keep every sentence, table row and list item that is still true word for
              word, and edit only what the new work makes wrong, such as a count, a list or a table.
            - Do not add headings or new sections. Do not claim a criterion passes or that checks ran.
            Do not write file system paths of the machine this ran on.
            """
        ]
        parts.append("## Current title\n\n\(PRDescriber.oneLine(input.current.title))")
        let editable = PRBodyRefresher.editable(in: input.current.body)
        for section in editable where !section.content.isEmpty {
            parts.append("## Section: \(section.name)\n\n~~~~\n\(section.content)\n~~~~")
        }
        parts.append("## What the new work was meant to do\n\n\(input.goal.request)")
        if !input.goal.outOfScope.isEmpty {
            parts.append(
                "## Out of scope\n\n"
                    + input.goal.outOfScope.map { "- \(PRDescriber.oneLine($0))" }.joined(separator: "\n"))
        }
        if !input.notes.isEmpty {
            let notes = input.notes.enumerated().map { "\($0.offset + 1). \(PRDescriber.oneLine($0.element))" }
            parts.append("## Feedback sent back during the work\n\n" + notes.joined(separator: "\n"))
        }
        if let result = input.turnResult, !result.isEmpty { parts.append("## The agent's last report\n\n" + result) }
        parts.append("## Check\n\n" + PRBodyBuilder.checkLine(input.check))
        if !input.commits.isEmpty {
            parts.append("## Commits added\n\n" + input.commits.map { "- \(PRDescriber.oneLine($0))" }.joined(separator: "\n"))
        }
        let cut = input.diffTruncated ? "\n\n(the diff was cut at \(PRDescriber.diffLimit) bytes)" : ""
        parts.append("## Diff of the new work\n\n```diff\n\(input.diff)\n```\(cut)")
        return PRBodyBuilder.scrub(parts.joined(separator: "\n\n"))
    }

    // MARK: Answer

    /// Reads `claude -p --output-format json` like `PRDescriber.parse`. A section the answer returns
    /// unchanged is dropped, so an answer that changes nothing comes back empty.
    public static func parse(output: String, current: PRText) throws -> PRRefresh {
        guard let outer = PRDescriber.object(from: output) else { throw PRDescribeError.invalidOutput("not JSON") }
        if outer["is_error"] as? Bool == true { throw PRDescribeError.claudeFailed("claude reported an error") }
        guard let text = outer["result"] as? String else { throw PRDescribeError.invalidOutput("no result") }
        guard let json = PRDescriber.object(from: text) else {
            throw PRDescribeError.invalidOutput("the answer is not a JSON object")
        }

        guard let rawTitle = json["title"] as? String else { throw PRDescribeError.invalidOutput("no title") }
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw PRDescribeError.invalidOutput("empty title") }
        guard !title.contains(where: \.isNewline) else { throw PRDescribeError.invalidOutput("the title has a newline") }
        // A title that was already longer is fine as long as it is left alone.
        guard title == current.title || title.count <= PRBodyBuilder.titleLimit else {
            throw PRDescribeError.invalidOutput("the title is \(title.count) characters, over \(PRBodyBuilder.titleLimit)")
        }

        let editable = Dictionary(
            PRBodyRefresher.editable(in: current.body).map { ($0.name, $0.content) }, uniquingKeysWith: { first, _ in first })
        var sections: [String: String] = [:]
        if let raw = json["sections"] {
            guard let given = raw as? [String: Any] else { throw PRDescribeError.invalidOutput("sections is not an object") }
            for (key, value) in given {
                let name = key.trimmingCharacters(in: .whitespaces).lowercased()
                guard let before = editable[name] else {
                    throw PRDescribeError.invalidOutput("'\(key)' is not a section of the pull request")
                }
                guard let after = value as? String else { throw PRDescribeError.invalidOutput("'\(key)' is not text") }
                let trimmed = after.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed != before { sections[name] = trimmed }
            }
        }
        return PRRefresh(title: title, sections: sections)
    }
}
