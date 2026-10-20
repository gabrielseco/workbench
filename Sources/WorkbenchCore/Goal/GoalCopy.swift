import Foundation

/// The front matter values a new draft takes from elsewhere instead of the config's defaults. `nil` keeps the default.
public struct GoalSettings: Sendable, Equatable {
    public var budgetUSD: Decimal?
    public var turnTimeoutMin: Int?
    public var model: String?

    public init(budgetUSD: Decimal? = nil, turnTimeoutMin: Int? = nil, model: String? = nil) {
        self.budgetUSD = budgetUSD
        self.turnTimeoutMin = turnTimeoutMin
        self.model = model
    }
}

/// What `goal new --from` takes from a goal file: the body, the settings that say how the work runs, and the names
/// of the front matter keys it leaves behind (they belong to the file's own thread).
public struct GoalCopy: Sendable, Equatable {
    public var body: GoalBody
    public var settings: GoalSettings
    public var ignoredKeys: [String]
}

/// A carried front matter value that the goal file rules refuse; the message names the key.
public struct GoalCopyValueError: Error, Equatable, Sendable, CustomStringConvertible {
    public let message: String
    public var description: String { message }
}

extension GoalFile {
    /// The front matter keys `goal new --from` carries into the draft.
    static let carriedKeys: Set<String> = ["budget_usd", "turn_timeout_min", "model"]

    /// Reads `text` for `goal new --from`. The front matter keys are not required here (the draft gets its own id,
    /// title, base and status), but the block must be well formed and the body must parse as a goal's. A carried value
    /// is checked by the same rules `parse` applies and throws `GoalCopyValueError`; any other problem throws
    /// `GoalParseError`.
    public static func copy(_ text: String) throws -> GoalCopy {
        var problems: [GoalProblem] = []
        func add(_ code: GoalProblem.Code, _ line: Int?, _ message: String) {
            problems.append(GoalProblem(code: code, line: line, message: message))
        }
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let (entries, closing) = try frontMatter(lines, add: add)
        let parsed = parseBody(lines, from: closing + 1, add: add)
        guard problems.isEmpty else {
            throw GoalParseError(problems: problems.sorted { ($0.line ?? .max) < ($1.line ?? .max) })
        }

        var settings = GoalSettings()
        for entry in entries where carriedKeys.contains(entry.key) {
            switch entry.key {
            case "budget_usd":
                guard let value = budgetValue(entry.value) else { throw GoalCopyValueError(message: budgetProblem(entry.value)) }
                settings.budgetUSD = value
            case "turn_timeout_min":
                guard let value = timeoutValue(entry.value) else {
                    throw GoalCopyValueError(message: timeoutProblem(entry.value))
                }
                settings.turnTimeoutMin = value
            default:
                guard SafeNames.isModelName(entry.value) else { throw GoalCopyValueError(message: modelProblem(entry.value)) }
                settings.model = entry.value
            }
        }
        let body = GoalBody(
            request: parsed.request,
            criteria: parsed.criteria.map { GoalBody.Criterion(id: $0.id, text: $0.text, proof: $0.proof) },
            outOfScope: parsed.outOfScope)
        let ignored = entries.map(\.key).filter { !carriedKeys.contains($0) }
        return GoalCopy(body: body, settings: settings, ignoredKeys: ignored)
    }
}
