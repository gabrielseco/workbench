import Foundation
import Testing

@testable import WorkbenchCore

@Suite struct RecordedDenialsTests {
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
        let long = String(repeating: "x", count: ThreadRunner.maxDeniedInputCharacters + 10)
        let line: [String: Any] = ["permission_denials": [["tool_name": "Bash", "tool_input": ["command": long]]]]
        guard case .array(let calls)? = ThreadRunner.deniedCalls(line), let call = calls.first else {
            Issue.record("no denials recorded")
            return
        }
        #expect(call["input"]?.stringValue?.count == ThreadRunner.maxDeniedInputCharacters)
        #expect(call["input_truncated"] == .bool(true))
    }

    @Test func oddShapesAreSkippedOrKeptWithoutAnInput() {
        let line: [String: Any] = [
            "permission_denials": [
                ["tool_name": "A"], ["tool_name": "B", "tool_input": 7], ["tool_input": ["command": "x"]], "junk",
            ],
        ]
        #expect(ThreadRunner.deniedCalls(line) == .array([.object(["tool": "A"]), .object(["tool": "B"])]))
    }
}
