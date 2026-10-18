import Foundation

extension ThreadRunner {
    static let maxRecordedDenials = 100
    static let maxDeniedInputCharacters = 4096
    private static let deniedInputKeys = ["command", "file_path", "path", "notebook_path", "url", "pattern", "query"]

    /// The turn's denied calls from the parsed `result` line, so the full command survives a result line the
    /// log had to cut for size. Raw text, bounded; whoever prints it makes it safe.
    static func deniedCalls(_ resultLine: [String: Any]?) -> JSONValue? {
        guard let denials = resultLine?["permission_denials"] as? [Any], !denials.isEmpty else { return nil }
        var calls: [JSONValue] = []
        for case let denial as [String: Any] in denials.prefix(maxRecordedDenials) {
            guard let tool = denial["tool_name"] as? String else { continue }
            var call: [String: JSONValue] = ["tool": .string(String(tool.prefix(200)))]
            let input = denial["tool_input"] as? [String: Any]
            if let text = deniedInputKeys.lazy.compactMap({ input?[$0] as? String }).first(where: { !$0.isEmpty }) {
                call["input"] = .string(String(text.prefix(maxDeniedInputCharacters)))
                if text.count > maxDeniedInputCharacters { call["input_truncated"] = true }
            }
            calls.append(.object(call))
        }
        return .array(calls)
    }
}
