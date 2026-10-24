import Foundation

/// Who reads the brief of a review stage. Only Codex: the reviewer is a second AI, never the one that wrote the change.
public enum ReviewerKind: String, Sendable, Equatable, CaseIterable {
    case codex
}

/// What a review stage may read: the diff against the base, the approved goal, the verify step's proof, or a file
/// of the repository.
public enum ReviewStageInput: Sendable, Equatable, CustomStringConvertible {
    case diff
    case goal
    case proof
    case path(String)

    public static let defaults: [ReviewStageInput] = [.diff, .goal]

    /// A path needs a `/` or an extension, so a misspelt keyword (`"proofs"`) is refused rather than read as a file.
    init?(_ text: String) {
        switch text {
        case "diff": self = .diff
        case "goal": self = .goal
        case "proof": self = .proof
        default:
            guard text.contains("/") || text.contains("."), PRReviewConfig.checklistProblem(text) == nil else { return nil }
            self = .path(text)
        }
    }

    public var description: String {
        switch self {
        case .diff: "diff"
        case .goal: "goal"
        case .proof: "proof"
        case .path(let path): path
        }
    }
}

/// One `[review.stage.<name>]` table, or a built-in stage's definition (docs/plan/P6-review-stages.md).
public struct ReviewStageConfig: Sendable, Equatable {
    public var name: String
    /// A repo-relative skill file whose rubric replaces the built-in prompt.
    public var skill: String?
    /// A repo-relative prompt file, the other way to give the rubric. Never set together with `skill`.
    public var prompt: String?
    public var checklist: String?
    public var reviewer: ReviewerKind = .codex
    /// `provider`, `model` and `allow_unpriced` of the stage's table; each overrides `[agents.review]` for this stage.
    public var provider: AgentProviderID?
    public var model: String?
    public var allowUnpriced: Bool?
    public var inputs: [ReviewStageInput] = ReviewStageInput.defaults
    /// Globs over the files the pull request changes. Empty means every change.
    public var appliesTo: [String] = []
    public var maxRounds: Int = PRReviewConfig.defaultMaxRounds

    public init(name: String) { self.name = name }

    /// The file the stage's rubric comes from, if it has one of its own.
    public var rubric: String? { skill ?? prompt }

    /// The most files a stage may read: each goes whole into the brief, up to `PRReview.checklistLimit`.
    public static let maxFileInputs = 8

    /// The repository files `inputs` names, in order, read from the pull request's checkout into the brief.
    public var fileInputs: [String] {
        inputs.compactMap { if case .path(let path) = $0 { path } else { nil } }
    }

    /// Whether the stage reads the verify step's proof.
    public var needsProof: Bool { inputs.contains(.proof) }
}

/// `[review]` and its `[review.stage.<name>]` tables: which review stages run, in what order, and how.
public struct ReviewConfig: Sendable, Equatable {
    public static let prReviewStage = "pr-review"
    /// Stages that need no table. Only `pr-review` has a definition of its own.
    public static let builtIn: Set<String> = [prReviewStage]
    public static let defaultStages = [prReviewStage]

    /// `review.stages`, in order.
    public var stages: [String] = ReviewConfig.defaultStages
    /// Every defined stage by name: the built-ins and each `[review.stage.<name>]` table, listed or not.
    public var definitions: [String: ReviewStageConfig] = [prReviewStage: ReviewStageConfig(name: prReviewStage)]
    /// The names that have a `[review.stage.<name>]` table, in file order.
    public var tables: [String] = []

    public init() {}

    public func stage(_ name: String) -> ReviewStageConfig? { definitions[name] }

    /// The `pr-review` stage as configured, listed in `stages` or not: `workbench pr-review` runs it either way.
    public var prReview: ReviewStageConfig {
        definitions[Self.prReviewStage] ?? ReviewStageConfig(name: Self.prReviewStage)
    }

    /// Tables that are not listed in `stages`: ignored by the loop, and `doctor` says so.
    public var unlistedTables: [String] { tables.filter { !stages.contains($0) } }

    /// A stage name ends up as a folder in the thread's directory, so it is kept to one plain lower-case word.
    static func isStageName(_ name: String) -> Bool {
        name.range(of: #"^[a-z0-9][a-z0-9_-]{0,39}$"#, options: .regularExpression) != nil
    }

    static let stageKeys: Set<String> = [
        "skill", "prompt", "checklist", "reviewer", "inputs", "applies_to", "max_rounds",
        "provider", "model", "allow_unpriced",
    ]
    static let tablePrefix = "review.stage."
}

// MARK: Parsing

extension ReviewConfig {
    typealias Fail = (ConfigProblem.Code, Int?, String) -> Void

    /// Whether `Config.parse` should leave this table to `parse(_:fail:)`.
    static func owns(table name: String) -> Bool {
        name == "review" || name == "pr_review" || name.hasPrefix(tablePrefix)
    }

    static func parse(_ document: TOMLDocument, fail: Fail) -> ReviewConfig {
        var config = ReviewConfig()
        for (name, table) in document.tables.sorted(by: { $0.value.line < $1.value.line }) where owns(table: name) {
            let known: Set<String>
            switch name {
            case "review": known = ["stages"]
            case "pr_review": known = ["checklist", "max_rounds"]
            default:
                let stage = String(name.dropFirst(tablePrefix.count))
                guard isStageName(stage) else {
                    fail(
                        .unknownTable, table.line,
                        "unknown table [\(name)]: a stage name is lower-case letters, digits, '-' and '_' (up to 40)")
                    continue
                }
                known = stageKeys
                config.tables.append(stage)
            }
            for (key, entry) in table.entries.sorted(by: { $0.key < $1.key }) where !known.contains(key) {
                fail(.unknownKey, entry.line, "unknown key '\(key)' in [\(name)]")
            }
        }

        // `[pr_review]` (P5) is the pr-review stage's table under its old name; two tables for one stage would
        // leave it unclear which one counts.
        let oldTable = document.tables["pr_review"]
        let newTable = document.tables[tablePrefix + prReviewStage]
        if let oldTable, let newTable {
            fail(
                .conflict, max(oldTable.line, newTable.line),
                "[pr_review] and [\(tablePrefix + prReviewStage)] both configure the pr-review stage; keep one")
        }
        if let oldTable {
            var stage = ReviewStageConfig(name: prReviewStage)
            stageSettings(oldTable, into: &stage, keys: ["checklist", "max_rounds"], fail: fail)
            config.definitions[prReviewStage] = stage
        }
        for name in config.tables {
            guard let table = document.tables[tablePrefix + name] else { continue }
            var stage = ReviewStageConfig(name: name)
            stageSettings(table, into: &stage, keys: stageKeys, fail: fail)
            config.definitions[name] = stage
        }

        if let entry = document.tables["review"]?.entries["stages"] {
            config.stages = stageList(entry, defined: config.definitions, fail: fail) ?? defaultStages
        }
        return config
    }

    private static func stageList(_ entry: TOMLEntry, defined: [String: ReviewStageConfig], fail: Fail) -> [String]? {
        guard case .array(let items) = entry.value else {
            fail(.wrongType, entry.line, "'stages' must be an array of stage names, found \(entry.value.typeName)")
            return nil
        }
        var names: [String] = []
        for item in items {
            guard case .string(let name) = item else {
                fail(.wrongType, entry.line, "'stages' must contain only strings, found \(item.typeName)")
                return nil
            }
            names.append(name)
        }
        if names.isEmpty { fail(.invalidValue, entry.line, "'stages' must list at least one stage") }
        var seen: Set<String> = []
        for name in names {
            if !seen.insert(name).inserted {
                fail(.invalidValue, entry.line, "'stages' lists '\(name)' more than once")
            } else if !isStageName(name) {
                fail(.invalidValue, entry.line, "'stages' entry '\(name)' is not a stage name")
            } else if defined[name] == nil {
                fail(
                    .missingKey, entry.line,
                    "'stages' lists '\(name)', which has no [\(tablePrefix)\(name)] table and is not a built-in stage")
            }
        }
        return names
    }

    private static func stageSettings(_ table: TOMLTable, into stage: inout ReviewStageConfig, keys: Set<String>, fail: Fail) {
        func path(_ key: String) -> String? {
            guard keys.contains(key), let entry = table.entries[key] else { return nil }
            guard case .string(let value) = entry.value else {
                fail(.wrongType, entry.line, "'\(key)' must be a string, found \(entry.value.typeName)")
                return nil
            }
            if let reason = PRReviewConfig.checklistProblem(value) {
                fail(.invalidValue, entry.line, "'\(key)' \(reason)")
                return nil
            }
            return value
        }
        func strings(_ key: String) -> (values: [String], line: Int)? {
            guard keys.contains(key), let entry = table.entries[key] else { return nil }
            guard case .array(let items) = entry.value else {
                fail(.wrongType, entry.line, "'\(key)' must be an array of strings, found \(entry.value.typeName)")
                return nil
            }
            var out: [String] = []
            for item in items {
                guard case .string(let value) = item else {
                    fail(.wrongType, entry.line, "'\(key)' must contain only strings, found \(item.typeName)")
                    return nil
                }
                out.append(value)
            }
            return (out, entry.line)
        }

        stage.skill = path("skill")
        stage.prompt = path("prompt")
        stage.checklist = path("checklist")
        if stage.skill != nil, stage.prompt != nil, let line = table.entries["prompt"]?.line {
            fail(.conflict, line, "'skill' and 'prompt' are both set in [\(tablePrefix)\(stage.name)]; the rubric comes from one")
        }
        if keys.contains("provider") {
            let selection = AgentSelection.parse(table, name: "\(tablePrefix)\(stage.name)", role: .review, fail: fail)
            stage.provider = selection.provider
            stage.model = selection.model
            stage.allowUnpriced = selection.allowUnpriced
        }
        if keys.contains("reviewer"), let entry = table.entries["reviewer"] {
            if let provider = table.entries["provider"] {
                fail(
                    .conflict, max(entry.line, provider.line),
                    "'reviewer' and 'provider' both choose the reviewer of [\(tablePrefix)\(stage.name)]; keep 'provider'")
            } else if case .string(let value) = entry.value, let reviewer = ReviewerKind(rawValue: value) {
                stage.reviewer = reviewer
                stage.provider = AgentProviderID(value)
            } else if case .string("claude") = entry.value {
                fail(
                    .invalidValue, entry.line,
                    "'reviewer' cannot be \"claude\": review stages run on Codex, the second AI that checks what "
                        + "Claude wrote; remove the key or set it to \"codex\"")
            } else {
                let allowed = ReviewerKind.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: " or ")
                fail(.invalidValue, entry.line, "'reviewer' must be \(allowed)")
            }
        }
        if let (values, line) = strings("inputs") {
            var inputs: [ReviewStageInput] = []
            for value in values {
                guard let input = ReviewStageInput(value) else {
                    fail(
                        .invalidValue, line,
                        "'inputs' entry '\(value)' is not \"diff\", \"goal\", \"proof\" or a file path in the repository")
                    continue
                }
                if !inputs.contains(input) { inputs.append(input) }
            }
            if values.isEmpty { fail(.invalidValue, line, "'inputs' must list at least one input") }
            let files = inputs.filter { if case .path = $0 { true } else { false } }.count
            if files > ReviewStageConfig.maxFileInputs {
                fail(.invalidValue, line, "'inputs' names \(files) files; at most \(ReviewStageConfig.maxFileInputs) are read")
            }
            stage.inputs = inputs
        }
        if let (values, line) = strings("applies_to") {
            for glob in values where PRReviewConfig.checklistProblem(glob) != nil {
                fail(.invalidValue, line, "'applies_to' entry '\(glob)' must be a path pattern inside the repository")
            }
            stage.appliesTo = values
        }
        if keys.contains("max_rounds"), let entry = table.entries["max_rounds"] {
            if case .int(let n) = entry.value, (1...PRReviewConfig.maxRoundsCeiling).contains(n) {
                stage.maxRounds = n
            } else {
                fail(
                    .invalidValue, entry.line,
                    "'max_rounds' must be a whole number from 1 to \(PRReviewConfig.maxRoundsCeiling)")
            }
        }
    }
}
