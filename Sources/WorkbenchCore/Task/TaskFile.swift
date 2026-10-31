import Foundation

public enum TaskFix: String, Sendable, Equatable {
    /// A read-only turn that writes a summary. The default: nothing leaves the machine.
    case report
    /// Does the work in a thread and, when the check and the verifier pass, accepts it and opens the pull request.
    case pr
}

/// One thing wrong with a task file. Parsing collects all of them, as the goal parser does.
public struct TaskProblem: Error, Equatable, Sendable, CustomStringConvertible {
    public var line: Int?
    public var message: String

    public var description: String {
        if let line { return "line \(line): \(message)" }
        return message
    }
}

public struct TaskParseError: Error, Equatable, Sendable, CustomStringConvertible {
    public var problems: [TaskProblem]

    public var description: String { problems.map(\.description).joined(separator: "\n") }
}

/// `task.md`: front matter the engine reads, a body Claude reads (docs/spec/tasks.md).
public struct TaskDefinition: Sendable, Equatable {
    public static let knownKeys: Set<String> = [
        "at", "days", "every", "batch", "include", "inputs", "pending", "fix", "budget",
    ]
    public static let maxBatch = 20
    public static let maxInputs = 20

    public let name: String
    public var schedule: TaskSchedule?
    public var batch: Int
    /// A skill file whose text goes into the prompt: Workbench starts Claude without loading skills.
    public var include: String?
    public var inputs: [String]
    /// A script that prints the units of work still to do.
    public var pending: String?
    public var fix: TaskFix
    public var budgetUSD: Decimal?
    public var instructions: String
    /// The file as read, line endings normalised: what the approval hash is made from.
    public let text: String

    /// A path in the project: relative, inside it, nothing git or a shell could read as an option. Whether it exists
    /// and stays inside after symlinks is checked where it is read.
    static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, path.count <= 200 else { return false }
        guard !path.hasPrefix("/"), !path.hasPrefix("-"), !path.hasPrefix("~") else { return false }
        guard !path.contains("\\"), !path.unicodeScalars.contains(where: { $0.value < 32 }) else { return false }
        return !path.split(separator: "/", omittingEmptySubsequences: false).dropLast(path.hasSuffix("/") ? 1 : 0)
            .contains { $0.isEmpty || $0 == ".." }
    }

    public static func parse(_ rawText: String, name: String) throws -> TaskDefinition {
        var problems: [TaskProblem] = []
        func add(_ line: Int?, _ message: String) { problems.append(TaskProblem(line: line, message: message)) }

        guard SafeNames.isThreadID(name) else {
            throw TaskParseError(problems: [TaskProblem(line: nil, message: "'\(name)' is not a usable task name")])
        }
        let text = rawText.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let front: (entries: [FrontMatterLine], closing: Int)
        do {
            front = try GoalFile.frontMatter(lines, knownKeys: knownKeys) { _, line, message in add(line, message) }
        } catch let error as GoalParseError {
            throw TaskParseError(problems: error.problems.map { TaskProblem(line: $0.line, message: $0.message) })
        }
        let entries = front.entries
        func entry(_ key: String) -> FrontMatterLine? { entries.first { $0.key == key } }

        let instructions = lines[(front.closing + 1)...].joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if instructions.isEmpty { add(front.closing + 1, "the task has no instructions below the front matter") }

        var definition = TaskDefinition(
            name: name, schedule: nil, batch: 1, include: nil, inputs: [], pending: nil, fix: .report,
            budgetUSD: nil, instructions: instructions, text: text)
        definition.schedule = schedule(entry("at"), entry("days"), entry("every"), add: add)

        if let e = entry("batch") {
            if let n = Int(e.value), (1...maxBatch).contains(n) {
                definition.batch = n
            } else {
                add(e.lineNumber, "'batch' must be a whole number from 1 to \(maxBatch), found '\(e.value)'")
            }
        }
        if let e = entry("fix") {
            if let fix = TaskFix(rawValue: e.value) {
                definition.fix = fix
            } else {
                add(e.lineNumber, "'fix' must be 'report' or 'pr', found '\(e.value)'")
            }
        }
        if let e = entry("budget") {
            if let budget = GoalFile.budgetValue(e.value) {
                definition.budgetUSD = budget
            } else {
                add(e.lineNumber, "'budget' must be a positive number, found '\(e.value)'")
            }
        }
        for key in ["include", "pending"] {
            guard let e = entry(key) else { continue }
            if isSafeRelativePath(e.value), !e.value.hasSuffix("/") {
                if key == "include" { definition.include = e.value } else { definition.pending = e.value }
            } else {
                add(e.lineNumber, "'\(key)' must be a file path inside the project, found '\(e.value)'")
            }
        }
        if let e = entry("inputs") {
            let items = list(e.value)
            if items.isEmpty || items.count > maxInputs || !items.allSatisfy(isSafeRelativePath) {
                add(e.lineNumber, "'inputs' must list 1 to \(maxInputs) paths inside the project, found '\(e.value)'")
            } else {
                definition.inputs = items
            }
        }
        guard problems.isEmpty else { throw TaskParseError(problems: problems.sorted { ($0.line ?? 0) < ($1.line ?? 0) }) }
        return definition
    }

    /// `[a, b]`, `a, b` or `"a"`: the items, trimmed, with surrounding quotes removed.
    private static func list(_ value: String) -> [String] {
        var inner = value.trimmingCharacters(in: .whitespaces)
        if inner.hasPrefix("["), inner.hasSuffix("]") { inner = String(inner.dropFirst().dropLast()) }
        return inner.split(separator: ",", omittingEmptySubsequences: false).map {
            var item = $0.trimmingCharacters(in: .whitespaces)
            if item.count >= 2, let q = item.first, q == "\"" || q == "'", item.last == q {
                item = String(item.dropFirst().dropLast())
            }
            return item
        }
    }

    private static func schedule(
        _ at: FrontMatterLine?, _ days: FrontMatterLine?, _ every: FrontMatterLine?, add: (Int?, String) -> Void
    ) -> TaskSchedule? {
        if at != nil, let every {
            add(every.lineNumber, "choose either 'at' or 'every', not both")
            return nil
        }
        if let every {
            if days != nil { add(days?.lineNumber, "'days' goes with 'at', not with 'every'") }
            if let match = every.value.wholeMatch(of: #/([0-9]+)([mhd])/#), let n = Int(match.1) {
                let unit = ["m": 60, "h": 3600, "d": 86_400][String(match.2)] ?? 0
                let seconds = n * unit
                if (TaskSchedule.minimumInterval...TaskSchedule.maximumInterval).contains(seconds) {
                    return .every(seconds: seconds)
                }
                add(every.lineNumber, "'every' must be from 5m to 30d, found '\(every.value)'")
            } else {
                add(every.lineNumber, "'every' must look like 30m, 1h or 1d, found '\(every.value)'")
            }
            return nil
        }
        guard let at else {
            if let days { add(days.lineNumber, "'days' needs an 'at' time of day") }
            return nil
        }
        guard let match = at.value.wholeMatch(of: #/([01]?[0-9]|2[0-3]):([0-5][0-9])/#),
            let hour = Int(match.1), let minute = Int(match.2)
        else {
            add(at.lineNumber, "'at' must be a time like 04:00, found '\(at.value)'")
            return nil
        }
        var daySet = Set(1...7)
        if let days {
            if let parsed = parseDays(days.value) {
                daySet = parsed
            } else {
                add(days.lineNumber, "'days' must be daily, weekdays or names like mon,wed, found '\(days.value)'")
                return nil
            }
        }
        return .daily(at: TimeOfDay(hour: hour, minute: minute), days: daySet)
    }

    private static func parseDays(_ value: String) -> Set<Int>? {
        let lowered = value.lowercased().trimmingCharacters(in: .whitespaces)
        if lowered == "daily" { return Set(1...7) }
        if lowered == "weekdays" { return Set(2...6) }
        var result = Set<Int>()
        for part in lowered.split(separator: ",", omittingEmptySubsequences: false) {
            guard let day = TaskSchedule.weekdayNames[part.trimmingCharacters(in: .whitespaces)] else { return nil }
            result.insert(day)
        }
        return result.isEmpty ? nil : result
    }
}
