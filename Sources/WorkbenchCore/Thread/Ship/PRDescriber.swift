import Foundation

/// What the describe step returns: the words only. The criteria table and the check line are never the
/// model's to write, so a description cannot tick a criterion or invent a check result.
public struct PRDescription: Sendable, Equatable {
    public var title: String
    public var summary: String
    /// Choices a reviewer should look at: where the work differs from what was assumed, and why.
    public var decisions: [String]
    /// Where the result departs from the goal.
    public var deviations: [String]
}

public enum PRDescribeError: Error, Equatable, Sendable, CustomStringConvertible {
    case claudeNotFound(String)
    case claudeFailed(String)
    case invalidOutput(String)

    public var description: String {
        switch self {
        case .claudeNotFound(let name): "`\(name)` was not found"
        case .claudeFailed(let why): why
        case .invalidOutput(let why): "the description was not usable: \(why)"
        }
    }
}

/// Everything the describing turn is told, assembled by Workbench. The model reads nothing else.
public struct PRDescribeInput: Sendable, Equatable {
    public var goal: Goal
    /// What the reviewer sent back, oldest first.
    public var notes: [String]
    /// The final message of the latest work turn, when there is one.
    public var turnResult: String?
    public var commits: [String]
    public var diff: String
    public var diffTruncated: Bool
    public var check: Review.Check?
}

/// The request to the describing turn and the reading of its answer. Pure: no process, no files.
public enum PRDescriber {
    public static let budgetUSD: Decimal = 0.5
    public static let timeout: TimeInterval = 120
    public static let diffLimit = 120_000
    public static let titleLimit = PRBodyBuilder.titleLimit
    static let itemLimit = 8

    // MARK: Request

    public static func prompt(for input: PRDescribeInput) -> String {
        var parts: [String] = [
            """
            You write the title and description of a pull request from the work that was actually done.
            You have no tools. Everything you may use is below. Reply with ONE JSON object and nothing else:
            {"title": string, "summary": string, "decisions": [string], "deviations": [string]}
            - title: Conventional Commits `type(scope): subject`, one line, at most \(titleLimit) characters.
            - summary: what changed and why, in a few short paragraphs of markdown, as built, not as planned.
            - decisions: choices a reviewer should check, each one sentence. [] when there are none.
            - deviations: where the result differs from the goal, each one sentence. [] when there are none.
            Do not claim a criterion passes or that checks ran; that is reported separately.
            Do not write file system paths of the machine this ran on.
            """
        ]
        parts.append("## Goal: \(oneLine(input.goal.title))\n\n\(input.goal.request)")
        if !input.goal.criteria.isEmpty {
            parts.append("## Criteria\n\n" + input.goal.criteria.map { "- \(oneLine($0.text))" }.joined(separator: "\n"))
        }
        if !input.goal.outOfScope.isEmpty {
            parts.append("## Out of scope\n\n" + input.goal.outOfScope.map { "- \(oneLine($0))" }.joined(separator: "\n"))
        }
        if !input.notes.isEmpty {
            let notes = input.notes.enumerated().map { "\($0.offset + 1). \(oneLine($0.element))" }
            parts.append("## Feedback sent back during the work\n\n" + notes.joined(separator: "\n"))
        }
        if let result = input.turnResult, !result.isEmpty {
            parts.append("## The agent's last report\n\n" + result)
        }
        parts.append("## Check\n\n" + PRBodyBuilder.checkLine(input.check))
        if !input.commits.isEmpty {
            parts.append("## Commits\n\n" + input.commits.map { "- \(oneLine($0))" }.joined(separator: "\n"))
        }
        let cut = input.diffTruncated ? "\n\n(the diff was cut at \(diffLimit) bytes)" : ""
        parts.append("## Diff against the base\n\n```diff\n\(input.diff)\n```\(cut)")
        return PRBodyBuilder.scrub(parts.joined(separator: "\n\n"))
    }

    /// The argv for the describing turn: no tools, its own session, its own budget. The prompt follows `--`.
    public static func arguments(config: Config, prompt: String, sessionID: UUID = UUID()) -> [String] {
        var args = [
            "-p", "--output-format", "json", "--permission-prompts", "none", "--restricted",
            "--session-id", sessionID.uuidString.lowercased(),
            "--max-budget-usd", NSDecimalNumber(decimal: budgetUSD).stringValue,
        ]
        if config.safeMode { args += ["--safe-mode", "--disable-slash-commands"] }
        if let model = config.model { args += ["--model", model] }
        args += ["--tools", "", "--", prompt]
        return args
    }

    /// The argv without the prompt, for the event log: the prompt is the diff and can be large.
    public static func displayArguments(_ arguments: [String]) -> [String] {
        guard let dashes = arguments.firstIndex(of: "--") else { return arguments }
        return Array(arguments[..<dashes])
    }

    // MARK: Answer

    /// Reads `claude -p --output-format json`: an object whose `result` holds the model's text, which is
    /// itself the JSON object asked for.
    public static func parse(output: String) throws -> PRDescription {
        guard let outer = object(from: output) else { throw PRDescribeError.invalidOutput("not JSON") }
        if outer["is_error"] as? Bool == true { throw PRDescribeError.claudeFailed("claude reported an error") }
        guard let text = outer["result"] as? String else { throw PRDescribeError.invalidOutput("no result") }
        guard let json = object(from: text) else { throw PRDescribeError.invalidOutput("the answer is not a JSON object") }

        guard let rawTitle = json["title"] as? String else { throw PRDescribeError.invalidOutput("no title") }
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw PRDescribeError.invalidOutput("empty title") }
        guard !title.contains(where: \.isNewline) else { throw PRDescribeError.invalidOutput("the title has a newline") }
        guard title.count <= titleLimit else {
            throw PRDescribeError.invalidOutput("the title is \(title.count) characters, over \(titleLimit)")
        }
        guard let rawSummary = json["summary"] as? String,
            !rawSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw PRDescribeError.invalidOutput("no summary") }

        func list(_ key: String) throws -> [String] {
            guard let value = json[key] else { return [] }
            guard let items = value as? [String] else { throw PRDescribeError.invalidOutput("\(key) is not a list of strings") }
            return items.map(oneLine).filter { !$0.isEmpty }.prefix(itemLimit).map { $0 }
        }
        return PRDescription(
            title: title, summary: rawSummary.trimmingCharacters(in: .whitespacesAndNewlines),
            decisions: try list("decisions"), deviations: try list("deviations"))
    }

    /// The outermost JSON object in `text`; models sometimes wrap it in a fence or a sentence.
    private static func object(from text: String) -> [String: Any]? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
        let slice = String(text[start...end])
        return (try? JSONSerialization.jsonObject(with: Data(slice.utf8))) as? [String: Any]
    }

    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
