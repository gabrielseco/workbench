/// One specific thing wrong with a goal file. Parsing collects all of them so the author fixes the file
/// once, not once per error. `line` is 1-based in the whole file, nil when the problem is about absence.
public struct GoalProblem: Error, Equatable, Sendable, CustomStringConvertible {
    public enum Code: Equatable, Sendable {
        case missingFrontMatter
        case unterminatedFrontMatter
        case malformedFrontMatterLine
        case duplicateKey
        case unknownKey
        case missingKey
        case invalidValue
        case missingSection
        case duplicateSection
        case emptySection
        case malformedCriterion
        case duplicateCriterionID
        case criterionWithoutProof
        case unrecognizedLine
    }

    public var code: Code
    public var line: Int?
    public var message: String

    public var description: String {
        if let line { return "line \(line): \(message)" }
        return message
    }
}

public struct GoalParseError: Error, Equatable, Sendable, CustomStringConvertible {
    public var problems: [GoalProblem]

    public var description: String {
        problems.map(\.description).joined(separator: "\n")
    }
}
