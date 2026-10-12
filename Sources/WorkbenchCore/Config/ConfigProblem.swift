/// One specific thing wrong with `config.toml`. Collected, with line numbers, like `GoalProblem`.
public struct ConfigProblem: Error, Equatable, Sendable, CustomStringConvertible {
    public enum Code: Equatable, Sendable {
        case notFound
        case unreadable
        case syntax
        case unsupportedSyntax
        case duplicateKey
        case duplicateTable
        case unknownKey
        case unknownTable
        case wrongType
        case invalidValue
        case missingKey
        case conflict
    }

    public var code: Code
    public var line: Int?
    public var message: String

    public var description: String {
        if let line { return "line \(line): \(message)" }
        return message
    }
}

public struct ConfigError: Error, Equatable, Sendable, CustomStringConvertible {
    public var problems: [ConfigProblem]

    public var description: String { problems.map(\.description).joined(separator: "\n") }
}
