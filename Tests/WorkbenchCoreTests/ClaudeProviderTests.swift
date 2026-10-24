import Foundation
import Testing

@testable import WorkbenchCore

private let session = "e79cf457-1714-495a-9ffe-526c12a4852e"

private let claudeConfig = """
    check_command = "scripts/check.sh"

    [tools]
    available = ["Read", "Edit", "Bash"]
    allowed = ["Read", "Edit", "Bash(git status:*)"]
    denied = ["Bash(git push:*)"]
    """

private func provider() throws -> ClaudeProvider { ClaudeProvider(config: try Config.parse(claudeConfig)) }

private func request(
    _ tweak: (inout AgentRequest) -> Void = { _ in }
) -> AgentRequest {
    var r = AgentRequest(
        provider: .claude, prompt: "Do the thing", workingDirectory: URL(fileURLWithPath: "/tmp"),
        outputDirectory: URL(fileURLWithPath: "/tmp"), policy: .scopedCoding, spend: .hardCap(5),
        session: .start(proposed: session), purpose: .coding, environment: ["PATH": "/usr/bin", "AWS_SECRET": "x"],
        limits: AgentLimits(timeout: 60), rules: "Be brief")
    tweak(&r)
    return r
}

private func exit(_ termination: Termination = .exited(0), tail: String = "", last: String? = nil) -> ProcessExit {
    ProcessExit(
        termination: termination, cause: .natural, durationMs: 1, escalatedToKill: false, sweptProcesses: 0,
        outputTruncated: last != nil, lastLineAfterLimit: last, stderrTail: tail, drainTimedOut: false)
}

@Suite struct ClaudeProviderInvocationTests {
    @Test func theArgvIsExactlyWhatTheConfigBuilds() throws {
        let turn = TurnRequest(
            sessionID: UUID(uuidString: session)!, resume: false, budgetUSD: 5, prompt: "Do the thing",
            appendSystemPrompt: "Be brief", model: "opus", extraAllowed: ["Bash(ls:*)"])
        let expected = try Config.parse(claudeConfig).invocation(for: turn)
        let built = try provider().invocation(for: request { $0.model = "opus"; $0.grants = ["Bash(ls:*)"] })
        #expect(built.arguments == expected.arguments)
        #expect(built.executable == expected.executable)
    }

    @Test func aResumeUsesTheHandleAndNotSessionId() throws {
        let handle = AgentSessionHandle(provider: .claude, purpose: .coding, value: session)
        let args = try provider().invocation(for: request { $0.session = .resume(handle) }).arguments
        let at = try #require(args.firstIndex(of: "--resume"))
        #expect(args[at + 1] == session)
        #expect(!args.contains("--session-id"))
    }

    @Test func theLogShowsTheArgvWithoutThePromptOrTheRules() throws {
        let built = try provider().invocation(for: request())
        #expect(!built.displayArguments.contains("Do the thing") && !built.displayArguments.contains("--"))
        let at = try #require(built.displayArguments.firstIndex(of: "--append-system-prompt"))
        #expect(built.displayArguments[at + 1] == "<rules>")
    }

    @Test func onlyTheConfigsEnvironmentReachesClaude() throws {
        let env = try provider().invocation(for: request()).environment
        #expect(env["PATH"] == "/usr/bin" && env["AWS_SECRET"] == nil)
    }

    @Test func theRequestsThatCannotBeHonouredAreRefusedNotBent() throws {
        let p = try provider()
        #expect(request { $0.spend = .timeoutOnly }.validate(against: p) == nil, "valid in general")
        #expect(throws: AgentFailure.self) { try p.invocation(for: request { $0.spend = .timeoutOnly }) }
        #expect(throws: AgentFailure.self) { try p.invocation(for: request { $0.session = .none }) }
        #expect(throws: AgentFailure.self) { try p.invocation(for: request { $0.session = .start(proposed: "not-a-uuid") }) }
        #expect(request { $0.policy = .readOnlyEvidence }.validate(against: p)?.kind == .unsupportedCapability)
        #expect(request { $0.images = [URL(fileURLWithPath: "/tmp/a.png")] }.validate(against: p) != nil)
    }
}

@Suite struct ClaudeDecoderTests {
    private func decoder() -> ClaudeDecoder { ClaudeDecoder(sessionID: session, purpose: .coding, maxRawBytes: 4096) }
    private let success = #"{"type":"result","subtype":"success","is_error":false,"result":"All done","total_cost_usd":0.0123}"#

    @Test func theFirstLineThatNamesTheSessionConfirmsItOnce() {
        var d = decoder()
        let first = d.consume(line: #"{"type":"system","subtype":"init","session_id":"\#(session)"}"#)
        #expect(first == [.session(AgentSessionHandle(provider: .claude, purpose: .coding, value: session))])
        #expect(d.consume(line: #"{"type":"stream_event","session_id":"\#(session)"}"#).isEmpty)
        var other = decoder()
        #expect(other.consume(line: #"{"type":"system","session_id":"other"}"#).isEmpty)
    }

    @Test func assistantTextAndToolCallsBecomeActivity() {
        var d = decoder()
        let line =
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"Looking"},"#
            + #"{"type":"tool_use","name":"Bash","input":{"command":"ls -la"}}]}}"#
        #expect(d.consume(line: line) == [.text("Looking"), .tool(name: "Bash", summary: "ls -la")])
        #expect(d.consume(line: "plain noise") == [.unknown(provider: .claude, raw: "plain noise")])
        #expect(d.consume(line: #"{"type":"stream_event"}"#).isEmpty, "partial messages are not flooded into activity")
    }

    @Test func theResultLineGivesTheSummaryCostAndOutcome() {
        var d = decoder()
        _ = d.consume(line: success)
        let r = d.finish(exit: exit())
        #expect(r.outcome == .succeeded && r.failure == nil)
        #expect(r.answer == .text("All done"))
        #expect(r.usage?.costUSD == 0.0123)
        #expect(r.lateLine == nil)
    }

    @Test(arguments: [0.0123, 0.0, 1.5, 0.00001234, 0.1 + 0.2, 12.345678901234])
    func theCostIsTheNumberTheResultLineHad(cost: Double) {
        var d = decoder()
        _ = d.consume(line: #"{"type":"result","subtype":"success","is_error":false,"total_cost_usd":\#(cost)}"#)
        #expect(d.finish(exit: exit()).usage?.costUSD == cost, "the log's cost_usd must not change by a rounding")
    }

    @Test func aBudgetStopIsItsOwnFailureAndASignalIsNot() {
        var d = decoder()
        _ = d.consume(line: #"{"type":"result","subtype":"error_max_budget_usd","is_error":true}"#)
        let r = d.finish(exit: exit(.exited(1)))
        #expect(r.failure?.kind == .budgetExceeded && r.outcome == .failed)

        var s = decoder()
        _ = s.consume(line: #"{"type":"result","subtype":"error_max_budget_usd"}"#)
        #expect(s.finish(exit: exit(.signaled(9))).failure == nil, "a killed process is a failure, not a budget stop")
    }

    @Test func aResultPastTheOutputLimitIsUsedAndHandedBackToBeRecorded() {
        var d = decoder()
        let r = d.finish(exit: exit(last: success))
        #expect(r.outcome == .succeeded && r.lateLine == success)

        var seen = decoder()
        _ = seen.consume(line: success)
        #expect(seen.finish(exit: exit(last: "something later")).lateLine == nil, "the stream already had a result")
    }

    @Test func deniedCallsAreBoundedAndCounted() {
        let many = (0..<150).map { #"{"tool_name":"Bash","tool_input":{"command":"c\#($0)"}}"# }.joined(separator: ",")
        var d = decoder()
        _ = d.consume(line: #"{"type":"result","subtype":"success","permission_denials":[\#(many)]}"#)
        let r = d.finish(exit: exit())
        #expect(r.permissionDenials.count == ClaudeDecoder.maxRecordedDenials)
        #expect(r.permissionDenialCount == 150)
        #expect(r.permissionDenials.first == AgentDenial(tool: "Bash", input: "c0"))
    }

    @Test func noResultLineIsAFailureNotASuccess() {
        var d = decoder()
        _ = d.consume(line: #"{"type":"system"}"#)
        #expect(d.finish(exit: exit()).outcome == .failed)
    }
}
