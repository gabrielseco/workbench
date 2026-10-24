import Foundation

extension ThreadRunner {
    /// The turn's denied calls as the log records them, so the full command survives a result line the log had
    /// to cut for size. Raw text, bounded by the decoder; whoever prints it makes it safe.
    static func deniedCalls(_ denials: [AgentDenial]) -> JSONValue? {
        guard !denials.isEmpty else { return nil }
        return .array(
            denials.map { denial in
                var call: [String: JSONValue] = ["tool": .string(denial.tool)]
                if let input = denial.input { call["input"] = .string(input) }
                if denial.inputTruncated { call["input_truncated"] = true }
                return .object(call)
            })
    }
}
