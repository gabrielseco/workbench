import Foundation

/// What a run says about why it stopped: the agent's last message, the commands it was denied, the end of a failed check's output.
/// All of it is text from outside (a model, a project's own scripts), so it is cut to size and stripped of control characters
/// before it reaches the log or a terminal.
public struct TaskExplanation: Sendable, Equatable {
    public static let maxMessage = 600
    public static let maxCommand = 120
    public static let maxDenied = 3
    public static let maxCheckLines = 8
    public static let maxCheckLine = 160
    public static let maxReason = 2000

    public var message: String?
    public var denied: [String] = []
    public var checkTail: [String] = []

    public init(message: String? = nil, denied: [String] = [], checkTail: [String] = []) {
        self.message = message.map { Self.clean($0, limit: Self.maxMessage) }.flatMap { $0.isEmpty ? nil : $0 }
        let commands = denied.map { Self.clean($0, limit: Self.maxCommand) }.filter { !$0.isEmpty }
        self.denied = Array(commands.prefix(Self.maxDenied))
        let lines = checkTail.map { Self.clean($0, limit: Self.maxCheckLine) }.filter { !$0.isEmpty }
        self.checkTail = Array(lines.suffix(Self.maxCheckLines))
    }

    /// One line: control characters gone, runs of whitespace (newlines included) made one space, cut at `limit` characters.
    public static func clean(_ text: String, limit: Int) -> String {
        let kept = text.unicodeScalars.map { scalar -> Character in
            scalar.properties.generalCategory == .control || scalar.properties.generalCategory == .format
                ? " " : Character(scalar)
        }
        let flat = String(kept).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard flat.count > limit else { return flat }
        return String(flat.prefix(max(0, limit - 1))) + "…"
    }

    /// `base`, then what the agent said, what it was denied, and the end of the check, as one bounded line.
    public func reason(_ base: String, includeCheck: Bool = false) -> String {
        var parts = [base]
        if let message { parts.append("the agent said: \(message)") }
        if !denied.isEmpty { parts.append("denied: " + denied.joined(separator: " | ")) }
        if includeCheck, !checkTail.isEmpty { parts.append("check output: " + checkTail.joined(separator: " / ")) }
        return Self.clean(parts.joined(separator: "; "), limit: Self.maxReason)
    }
}
