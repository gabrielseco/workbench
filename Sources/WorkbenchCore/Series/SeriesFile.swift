import Foundation

/// Where a project keeps its series (docs/spec/series.md, P27):
///
///     <repo>/.workbench/series/<name>/series.md, approval.json, and the goal files the steps name
extension Project {
    public var seriesDirectory: URL { workbenchDirectory.appendingPathComponent("series") }

    public func seriesDirectory(_ name: String) -> URL { seriesDirectory.appendingPathComponent(name) }
}

public struct SeriesProblem: Error, Equatable, Sendable, CustomStringConvertible {
    public var line: Int?
    public var message: String

    public var description: String { line.map { "line \($0): \(message)" } ?? message }
}

public struct SeriesParseError: Error, Equatable, Sendable, CustomStringConvertible {
    public var problems: [SeriesProblem]

    public var description: String { problems.map(\.description).joined(separator: "\n") }
}

/// One step of a series: a goal file to run in a project, and where it starts.
public struct SeriesStep: Sendable, Equatable {
    /// Where an `env` value comes from: a literal, or the branch of an earlier step's thread.
    public enum EnvValue: Sendable, Equatable {
        case literal(String)
        case stepBranch(Int)
    }

    /// Where the step's thread is cut from.
    public enum Base: Sendable, Equatable {
        /// The project's own base, or this branch of it.
        case branch(String?)
        /// The branch of an earlier step's thread (same project), which becomes the step's `--after`.
        case after(Int)
    }

    public var number: Int
    /// An absolute path: `~/` is expanded when the file is read.
    public var project: String
    /// A file name in the series folder, the goal as `goal new --from` takes it.
    public var goal: String
    public var base: Base
    /// Earlier steps that must be clean first (a `base: after N` step names N too).
    public var after: [Int]
    public var env: [(name: String, value: EnvValue)]

    public static func == (a: SeriesStep, b: SeriesStep) -> Bool {
        a.number == b.number && a.project == b.project && a.goal == b.goal && a.base == b.base && a.after == b.after
            && a.env.count == b.env.count && zip(a.env, b.env).allSatisfy { $0.name == $1.name && $0.value == $1.value }
    }
}

/// `series.md`: an optional front matter block and one `## N` section per step, each of `key: value` lines.
public struct SeriesDefinition: Sendable, Equatable {
    private struct Section {
        var number: Int
        var line: Int
        var entries: [FrontMatterLine] = []
    }

    public static let knownKeys: Set<String> = ["budget_usd"]
    public static let stepKeys: Set<String> = ["project", "goal", "base", "after", "env"]
    public static let maxSteps = 10
    public static let maxEnv = 5

    public let name: String
    public var budgetUSD: Decimal?
    public var steps: [SeriesStep]
    /// The file as read, line endings normalised.
    public let text: String

    static func isSafeGoalFile(_ file: String) -> Bool {
        file.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,99}\.md$"#, options: .regularExpression) != nil && file != "series.md"
    }

    static func isEnvName(_ name: String) -> Bool {
        name.range(of: #"^[A-Z][A-Z0-9_]{0,63}$"#, options: .regularExpression) != nil
    }

    static func isEnvLiteral(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._/@:+-]{0,199}$"#, options: .regularExpression) != nil
    }

    /// An absolute path, or `~/` and one. No `..`, no control characters, nothing an option could be read from.
    static func isSafeProjectPath(_ path: String) -> Bool {
        guard path.hasPrefix("/") || path.hasPrefix("~/"), path.count <= 300, !path.contains("\\") else { return false }
        if path.unicodeScalars.contains(where: { $0.value < 32 }) { return false }
        return !path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().contains { $0 == ".." || $0.isEmpty }
    }

    public static func parse(_ rawText: String, name: String) throws -> SeriesDefinition {
        var problems: [SeriesProblem] = []
        func add(_ line: Int?, _ message: String) { problems.append(SeriesProblem(line: line, message: message)) }
        guard SafeNames.isThreadID(name) else {
            throw SeriesParseError(problems: [SeriesProblem(line: nil, message: "'\(name)' is not a usable series name")])
        }
        let text = rawText.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        var budget: Decimal?
        var start = 0
        if lines.first == "---" {
            guard let closing = lines.indices.dropFirst().first(where: { lines[$0] == "---" }) else {
                throw SeriesParseError(problems: [SeriesProblem(line: 1, message: "front matter has no closing '---'")])
            }
            var seen = Set<String>()
            for index in 1..<closing {
                let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
                guard let entry = FrontMatterLine(raw: lines[index], lineNumber: index + 1) else {
                    add(index + 1, "expected 'key: value', found '\(trimmed)'")
                    continue
                }
                if !knownKeys.contains(entry.key) {
                    add(index + 1, "unknown key '\(entry.key)'")
                } else if !seen.insert(entry.key).inserted {
                    add(index + 1, "key '\(entry.key)' appears more than once")
                } else if let value = GoalFile.budgetValue(entry.value) {
                    budget = value
                } else {
                    add(index + 1, "'budget_usd' must be a positive number, found '\(entry.value)'")
                }
            }
            start = closing + 1
        }

        var sections: [Section] = []
        for index in start..<lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") && !trimmed.hasPrefix("##") { continue }
            if trimmed.hasPrefix("##") {
                let label = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
                guard let n = Int(label), n >= 1 else {
                    add(index + 1, "a step is written '## N' with N the step's number, found '\(trimmed)'")
                    sections.append(Section(number: 0, line: index + 1))
                    continue
                }
                sections.append(Section(number: n, line: index + 1))
                continue
            }
            guard !sections.isEmpty else {
                add(index + 1, "text before the first '## 1' step: '\(trimmed)'")
                continue
            }
            guard let entry = FrontMatterLine(raw: lines[index], lineNumber: index + 1) else {
                add(index + 1, "expected 'key: value', found '\(trimmed)'")
                continue
            }
            sections[sections.count - 1].entries.append(entry)
        }
        if sections.isEmpty { add(nil, "the series has no steps: write '## 1' and its keys") }
        if sections.count > maxSteps { add(nil, "a series has at most \(maxSteps) steps, found \(sections.count)") }

        var steps: [SeriesStep] = []
        for (position, section) in sections.enumerated() {
            if section.number != position + 1 {
                add(
                    section.line,
                    "steps are numbered 1, 2, 3 in order: this one is '## \(section.number)', expected '## \(position + 1)'")
            }
            if let step = step(section.number, position + 1, section.line, section.entries, add: add) { steps.append(step) }
        }
        guard problems.isEmpty else { throw SeriesParseError(problems: problems) }
        return SeriesDefinition(name: name, budgetUSD: budget, steps: steps, text: text)
    }

    private static func step(
        _ number: Int, _ position: Int, _ line: Int, _ entries: [FrontMatterLine], add: (Int?, String) -> Void
    ) -> SeriesStep? {
        var failed = false
        func fail(_ at: Int, _ message: String) {
            add(at, "step \(position): \(message)")
            failed = true
        }
        var seen = Set<String>()
        for entry in entries {
            if !stepKeys.contains(entry.key) {
                fail(entry.lineNumber, "unknown key '\(entry.key)'")
            } else if !seen.insert(entry.key).inserted {
                fail(entry.lineNumber, "key '\(entry.key)' appears more than once")
            }
        }
        func value(_ key: String) -> FrontMatterLine? { entries.first { $0.key == key } }
        func earlier(_ text: String, _ at: Int, _ key: String) -> Int? {
            guard let n = Int(text), n >= 1 else {
                fail(at, "'\(key)' names a step by its number, found '\(text)'")
                return nil
            }
            guard n < position else {
                fail(at, "'\(key)' names step \(n), which does not come before this one")
                return nil
            }
            return n
        }

        var project = ""
        if let e = value("project") {
            if isSafeProjectPath(e.value) { project = e.value } else {
                fail(e.lineNumber, "'project' must be an absolute path or ~/…, without '..', found '\(e.value)'")
            }
        } else { fail(line, "'project' is missing") }
        var goal = ""
        if let e = value("goal") {
            if isSafeGoalFile(e.value) { goal = e.value } else {
                fail(e.lineNumber, "'goal' must be a file name ending in .md in the series folder, found '\(e.value)'")
            }
        } else { fail(line, "'goal' is missing") }

        var base = SeriesStep.Base.branch(nil)
        var after: [Int] = []
        if let e = value("base") {
            if e.value.hasPrefix("after ") {
                if let n = earlier(e.value.dropFirst("after ".count).trimmingCharacters(in: .whitespaces), e.lineNumber, "base") {
                    base = .after(n)
                    after.append(n)
                }
            } else if SafeNames.isBranchName(e.value), !e.value.hasSuffix("/") {
                base = .branch(e.value)
            } else {
                fail(e.lineNumber, "'base' must be a branch name or 'after N', found '\(e.value)'")
            }
        }
        if let e = value("after") {
            for part in e.value.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                if let n = earlier(part, e.lineNumber, "after"), !after.contains(n) { after.append(n) }
            }
        }
        var env: [(name: String, value: SeriesStep.EnvValue)] = []
        if let e = value("env") {
            let items = e.value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if items.isEmpty || items.count > maxEnv { fail(e.lineNumber, "'env' lists 1 to \(maxEnv) NAME=value pairs") }
            for item in items {
                let pair = item.split(separator: "=", maxSplits: 1).map(String.init)
                guard pair.count == 2, isEnvName(pair[0]) else {
                    fail(e.lineNumber, "'env' has '\(item)': write NAME=value with NAME in capitals, digits and _")
                    continue
                }
                if env.contains(where: { $0.name == pair[0] }) {
                    fail(e.lineNumber, "'env' sets \(pair[0]) twice")
                } else if pair[1].hasPrefix("step:") {
                    if let n = earlier(String(pair[1].dropFirst("step:".count)), e.lineNumber, "env") {
                        env.append((pair[0], .stepBranch(n)))
                    }
                } else if isEnvLiteral(pair[1]) {
                    env.append((pair[0], .literal(pair[1])))
                } else {
                    fail(e.lineNumber, "'env' value '\(pair[1])' is neither step:N nor a plain word")
                }
            }
        }
        guard !failed else { return nil }
        return SeriesStep(number: number, project: project, goal: goal, base: base, after: after.sorted(), env: env)
    }
}
