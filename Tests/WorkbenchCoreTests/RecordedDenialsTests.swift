import Foundation
import Testing

@testable import WorkbenchCore

@Suite(.processGate) struct RecordedDenialsTests {
    /// What the log records for a parsed `result` line: the adapter bounds and shapes the denials, the runner
    /// writes them.
    private func recorded(_ line: [String: Any]) -> JSONValue? {
        ThreadRunner.deniedCalls(ClaudeDecoder.denials(line).0)
    }

    private func firstDenial(_ fx: RunnerFixture, _ id: String) throws -> JSONValue? {
        guard case .array(let calls)? = ended(try fx.events(id))[0].data["denials"] else { return nil }
        return calls.first
    }

    @Test func theEndOfATurnKeepsTheFullDeniedCommand() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        let command = "for n in 1 2 3; do gh pr view $n --json state; done && git fetch origin"
        _ = try await fx.runner(id).run(fx.options("deny=\(command)"))
        #expect(try firstDenial(fx, id) == .object(["tool": "Bash", "input": .string(command)]))
    }

    @Test func noDenialsLeavesNoDenialsField() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        _ = try await fx.runner(id).run(fx.options())
        #expect(ended(try fx.events(id))[0].data["denials"] == nil)
    }

    @Test func aVeryLongDeniedCommandIsCutAndSaysSo() {
        let long = String(repeating: "x", count: ClaudeDecoder.maxDeniedInputCharacters + 10)
        let line: [String: Any] = ["permission_denials": [["tool_name": "Bash", "tool_input": ["command": long]]]]
        guard case .array(let calls)? = recorded(line), let call = calls.first else {
            Issue.record("no denials recorded")
            return
        }
        #expect(call["input"]?.stringValue?.count == ClaudeDecoder.maxDeniedInputCharacters)
        #expect(call["input_truncated"] == .bool(true))
    }

    @Test func oddShapesAreSkippedOrKeptWithoutAnInput() {
        let line: [String: Any] = [
            "permission_denials": [
                ["tool_name": "A"], ["tool_name": "B", "tool_input": 7], ["tool_input": ["command": "x"]], "junk",
            ],
        ]
        #expect(recorded(line) == .array([.object(["tool": "A"]), .object(["tool": "B"])]))
    }
}
