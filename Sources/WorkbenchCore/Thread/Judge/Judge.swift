import Foundation

/// One criterion's verdict from the advisory judge.
public struct JudgeCriterion: Sendable, Equatable {
    public var id: String
    public var met: Bool
    /// What the verdict rests on: a check result, a line of the diff, what a screenshot shows.
    public var evidence: [String]
}

/// What the judge said: per criterion, and anything else worth a person's attention. Advisory: nothing in
/// Workbench acts on it, and it is shown next to a person's own ticks.
public struct JudgeVerdict: Sendable, Equatable {
    public var criteria: [JudgeCriterion]
    public var concerns: [String]
}

public enum JudgeError: Error, Equatable, Sendable, CustomStringConvertible {
    case claudeNotFound(String)
    case claudeFailed(String)
    case invalidOutput(String)

    public var description: String {
        switch self {
        case .claudeNotFound(let name): "`\(name)` was not found"
        case .claudeFailed(let why): why
        case .invalidOutput(let why): "the verdict was not usable: \(why)"
        }
    }
}

/// Everything the judge is told, assembled by Workbench. The only other thing it can read is the screenshots
/// in its working directory.
public struct JudgeInput: Sendable, Equatable {
    public var goal: Goal
    public var diff: String
    public var diffTruncated: Bool
    public var check: Review.Check?
    /// The last lines of the check's output, when it did not pass.
    public var checkOutput: String?
    public var verify: Review.Verify?
    /// Screenshot file names, relative to the judge's working directory, that it may look at.
    public var screenshots: [String]
    /// Pixel size of a screenshot by file name, when it could be read, so a clipped capture can be named.
    public var screenshotSizes: [String: PNGSize] = [:]
    /// The newest turn, so a check or verify from an earlier one can be called stale.
    public var lastTurn: Int
    /// Files in the worktree that git does not track, so not in the diff. Names only.
    public var untracked: [String] = []
}

/// The request to the judge and the reading of its answer. Pure: no process, no files.
public enum Judge {
    public static let budgetUSD: Decimal = 0.5
    public static let timeout: TimeInterval = 300
    public static let diffLimit = 120_000
    static let evidencePerCriterion = 3
    static let evidenceLimit = 300
    static let concernLimit = 8

    // MARK: Request

    public static func prompt(for input: JudgeInput) -> String {
        var parts: [String] = [
            """
            You are an independent judge of one piece of work. You did not write it. Decide, for each criterion \
            of the goal, whether the evidence below shows it holds. Everything you may use is below, plus the \
            screenshot files listed, which you may open with the Read tool (and nothing else).
            Reply with ONE JSON object and nothing else:
            {"criteria": [{"id": string, "met": boolean, "evidence": [string]}], "concerns": [string]}
            Rules:
            - One entry per criterion, using its id. evidence: at most \(evidencePerCriterion) short sentences \
            saying what you saw or read that decides it.
            - "met": false only for an evidenced violation of the criterion's literal text. If the evidence \
            does not settle it, put that in "concerns" and do not mark it unmet.
            - concerns: things a reviewer should look at that no criterion covers, one sentence each. [] if none.
            - You judge; you do not run anything, and you do not redo the project's checks.
            - Do not write file system paths of the machine this ran on.
            """
        ]
        parts.append("## Goal: \(oneLine(input.goal.title))\n\n\(input.goal.request)")
        let criteria = input.goal.criteria.map { "- [\($0.id)] \(oneLine($0.text))\n  - proof: \(oneLine($0.proof))" }
        parts.append("## Criteria\n\n" + criteria.joined(separator: "\n"))
        if !input.goal.outOfScope.isEmpty {
            parts.append("## Out of scope\n\n" + input.goal.outOfScope.map { "- \(oneLine($0))" }.joined(separator: "\n"))
        }
        parts.append("## Check\n\n" + checkText(input))
        parts.append("## Verify step\n\n" + verifyText(input))
        if input.screenshots.isEmpty {
            parts.append("## Screenshots\n\nNone.")
        } else {
            parts.append(
                "## Screenshots\n\nOpen these with Read (they are in your working directory):\n\n"
                    + input.screenshots.map { name in
                        input.screenshotSizes[name].map { "- \(name) (\($0.width) × \($0.height) px)" } ?? "- \(name)"
                    }.joined(separator: "\n")
                    + "\n\nIf a capture looks cut off or too small to read, say so in \"concerns\".")
        }
        let cut = input.diffTruncated ? "\n\n(the diff was cut at \(diffLimit) bytes)" : ""
        parts.append("## Diff against the base\n\n```diff\n\(input.diff)\n```\(cut)")
        if !input.untracked.isEmpty {
            parts.append(
                "## Untracked files (not in the diff)\n\n" + input.untracked.map { "- \(oneLine($0))" }.joined(separator: "\n"))
        }
        return PRBodyBuilder.scrub(parts.joined(separator: "\n\n"))
    }

    private static func checkText(_ input: JudgeInput) -> String {
        guard let check = input.check else { return "The project's check did not run." }
        var text = PRBodyBuilder.checkLine(check)
        if let command = check.command { text += " The command was `\(oneLine(command))`." }
        if check.turn != input.lastTurn { text += " This was after turn \(check.turn), not the latest turn \(input.lastTurn)." }
        if let output = input.checkOutput, !output.isEmpty { text += "\n\nEnd of its output:\n\n```\n\(output)\n```" }
        return text
    }

    private static func verifyText(_ input: JudgeInput) -> String {
        guard let verify = input.verify else { return "No verify step ran." }
        var text = "The project's verify step ended \(verify.result.replacingOccurrences(of: "_", with: " ")) "
        text += "after turn \(verify.turn)"
        text += verify.turn == input.lastTurn ? "." : " (the latest turn is \(input.lastTurn))."
        let files = verify.proof.map(\.name).joined(separator: ", ")
        text += verify.proof.isEmpty ? " It left no files." : " It left: \(files)."
        return text
    }

    /// The argv for the judge: read-only, its own session and budget. With screenshots it gets `Read` and
    /// runs in the folder that holds them, which `--restricted` then makes the only place it can read; with
    /// none it has no tools. The prompt follows `--`.
    public static func arguments(
        config: Config, prompt: String, withScreenshots: Bool, budget: Decimal = budgetUSD, model: String? = nil,
        sessionID: UUID = UUID()
    ) -> [String] {
        var args = [
            "-p", "--output-format", "json", "--permission-prompts", "none", "--restricted",
            "--session-id", sessionID.uuidString.lowercased(),
            "--max-budget-usd", NSDecimalNumber(decimal: budget).stringValue,
        ]
        if config.safeMode { args += ["--safe-mode", "--disable-slash-commands"] }
        if let model = model ?? config.model { args += ["--model", model] }
        args += withScreenshots ? ["--tools", "Read", "--allowedTools", "Read"] : ["--tools", ""]
        args += ["--", prompt]
        return args
    }

    // MARK: Answer

    /// Reads `claude -p --output-format json`, whose `result` is the JSON object asked for, and checks it against
    /// the goal: every criterion exactly once, no id the goal does not have.
    public static func parse(output: String, criteria: [Criterion]) throws -> (verdict: JudgeVerdict, costUSD: Double?) {
        guard let outer = PRDescriber.object(from: output) else { throw JudgeError.invalidOutput("not JSON") }
        if outer["is_error"] as? Bool == true { throw JudgeError.claudeFailed("claude reported an error") }
        guard let text = outer["result"] as? String else { throw JudgeError.invalidOutput("no result") }
        guard let json = PRDescriber.object(from: text) else {
            throw JudgeError.invalidOutput("the answer is not a JSON object")
        }
        guard let entries = json["criteria"] as? [[String: Any]] else {
            throw JudgeError.invalidOutput("no list of criteria")
        }
        let known = Set(criteria.map(\.id))
        var seen = Set<String>()
        var verdicts: [JudgeCriterion] = []
        for entry in entries {
            guard let id = entry["id"] as? String, known.contains(id) else {
                throw JudgeError.invalidOutput("an entry names a criterion the goal does not have")
            }
            guard seen.insert(id).inserted else { throw JudgeError.invalidOutput("[\(id)] appears twice") }
            guard let met = jsonBool(entry["met"]) else {
                throw JudgeError.invalidOutput("[\(id)] has no true or false 'met'")
            }
            guard let evidence = entry["evidence"] as? [String] else {
                throw JudgeError.invalidOutput("[\(id)] has no list of strings 'evidence'")
            }
            verdicts.append(
                JudgeCriterion(
                    id: id, met: met,
                    evidence: evidence.map(oneLine).filter { !$0.isEmpty }.prefix(evidencePerCriterion)
                        .map { String($0.prefix(evidenceLimit)) }))
        }
        let missing = criteria.map(\.id).filter { !seen.contains($0) }
        guard missing.isEmpty else {
            throw JudgeError.invalidOutput("no verdict for " + missing.map { "[\($0)]" }.joined(separator: ", "))
        }
        guard let list = json["concerns"] as? [String] else {
            throw JudgeError.invalidOutput("no list of strings 'concerns'")
        }
        let concerns = list.map(oneLine).filter { !$0.isEmpty }.prefix(concernLimit).map { String($0.prefix(evidenceLimit)) }
        let order = Dictionary(uniqueKeysWithValues: criteria.enumerated().map { ($1.id, $0) })
        verdicts.sort { (order[$0.id] ?? 0) < (order[$1.id] ?? 0) }
        return (JudgeVerdict(criteria: verdicts, concerns: concerns), (outer["total_cost_usd"] as? NSNumber)?.doubleValue)
    }

    /// A JSON `true` or `false`, and not the number 1 or 0 that Foundation would also bridge to a Bool.
    static func jsonBool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// Width and height of a PNG, read from its header.
public struct PNGSize: Sendable, Equatable {
    public var width: Int
    public var height: Int

    /// The 8-byte signature, then the `IHDR` chunk: 4 bytes of length, its name, width, height (big endian).
    public static func parse(_ head: Data) -> PNGSize? {
        let bytes = [UInt8](head.prefix(24))
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard bytes.count == 24, Array(bytes[0..<8]) == signature, Array(bytes[12..<16]) == Array("IHDR".utf8) else {
            return nil
        }
        func value(_ at: Int) -> Int { bytes[at..<at + 4].reduce(0) { $0 << 8 | Int($1) } }
        let width = value(16), height = value(20)
        return width > 0 && height > 0 ? PNGSize(width: width, height: height) : nil
    }

    public static func read(at url: URL) -> PNGSize? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 24)).flatMap(parse)
    }
}
