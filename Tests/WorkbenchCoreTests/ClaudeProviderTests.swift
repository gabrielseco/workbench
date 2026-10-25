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

private func judgeRequest(_ tweak: (inout AgentRequest) -> Void = { _ in }) -> AgentRequest {
    request {
        $0.policy = .readOnlyEvidence
        $0.purpose = .judge
        $0.session = .start(proposed: session)
        $0.spend = .hardCap(0.5)
        $0.rules = nil
        tweak(&$0)
    }
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

    @Test func aTimeoutOnlyTurnRunsWithoutADollarCap() throws {
        let capped = try provider().invocation(for: request()).arguments
        #expect(capped.contains("--max-budget-usd"))
        let free = try provider().invocation(for: request { $0.spend = .timeoutOnly }).arguments
        #expect(!free.contains("--max-budget-usd"), "nothing enforces a cap, so none is passed")
        #expect(free.filter { $0 != "--max-budget-usd" } == capped.filter { $0 != "--max-budget-usd" && $0 != "5" })
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
        #expect(throws: AgentFailure.self) { try p.invocation(for: request { $0.session = .none }) }
        #expect(throws: AgentFailure.self) { try p.invocation(for: request { $0.session = .start(proposed: "not-a-uuid") }) }
        #expect(request { $0.policy = .readOnlyEvidence }.validate(against: p) != nil, "a coding purpose with a read-only policy")
        #expect(judgeRequest { $0.spend = .hardCap(1) }.validate(against: p) == nil, "valid in general")
        #expect(throws: AgentFailure.self) { try p.invocation(for: judgeRequest { $0.spend = .timeoutOnly }) }
        #expect(throws: AgentFailure.self) { try p.invocation(for: judgeRequest { $0.grants = ["Bash(ls:*)"] }) }
        let handle = AgentSessionHandle(provider: .claude, purpose: .judge, value: session)
        #expect(throws: AgentFailure.self) { try p.invocation(for: judgeRequest { $0.session = .resume(handle) }) }
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
        let future = #"{"type":"future_diagnostic","message":"look"}"#
        #expect(d.consume(line: future) == [.unknown(provider: .claude, raw: future)], "a newer Claude's event is kept")
        let untyped = #"{"message":"no type"}"#
        #expect(d.consume(line: untyped) == [.unknown(provider: .claude, raw: untyped)])
        let typeLater = #"{"session":"x","type":"future"}"#
        #expect(d.consume(line: typeLater) == [.unknown(provider: .claude, raw: typeLater)])
        #expect(d.consume(line: #"{"session":"x","type":"user"}"#).isEmpty, "a known type is found even when not first")
        #expect(d.consume(line: #"{"type":"stream_event"}"#).isEmpty, "partial messages are not flooded into activity")
    }

    @Test func aRefusedCallBecomesADeniedActivityNamingItsTool() {
        var d = decoder()
        _ = d.consume(
            line: #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","#
                + #""input":{"command":"git push"}}]}}"#)
        let refused =
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","is_error":true,"#
            + #""content":"Permission for this tool use was denied. The user did not allow it."}]}}"#
        #expect(d.consume(line: refused) == [.permissionDenied(tool: "Bash")])
        let failed =
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","#
            + #""is_error":true,"content":"exit 1"}]}}"#
        #expect(d.consume(line: failed).isEmpty, "a command that merely failed is not a refusal")
        let unknownTool = refused.replacingOccurrences(of: "t1", with: "never-seen")
        #expect(d.consume(line: unknownTool) == [.permissionDenied(tool: "tool")], "still counted when the tool is unknown")
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

@Suite struct ClaudeCodingEffortTests {
    @Test func aCodingTurnCarriesTheModelAndEffortToClaude() throws {
        let args = try provider().invocation(for: request { $0.model = "opus"; $0.reasoningEffort = "high" }).arguments
        #expect(args[try #require(args.firstIndex(of: "--model")) + 1] == "opus")
        #expect(args[try #require(args.firstIndex(of: "--effort")) + 1] == "high")
        #expect(try !provider().invocation(for: request()).arguments.contains("--effort"))
    }
}

@Suite struct ClaudeReadOnlyTests {
    private func argv(_ config: String = claudeConfig, _ tweak: (inout AgentRequest) -> Void = { _ in }) throws -> [String] {
        try ClaudeProvider(config: try Config.parse(config)).invocation(for: judgeRequest(tweak)).arguments
    }

    @Test func anEffortIsPassedToClaudeOnlyWhenChosen() throws {
        let args = try argv { $0.reasoningEffort = "xhigh" }
        #expect(args[try #require(args.firstIndex(of: "--effort")) + 1] == "xhigh")
        #expect(try !argv().contains("--effort"))
    }

    @Test func aJudgeIsConfinedOneShotAndCapped() throws {
        let args = try argv { $0.model = "haiku" }
        #expect(args.contains("--restricted") && args.contains("--permission-prompts"))
        #expect(!args.contains("--resume") && !args.contains("--append-system-prompt"))
        #expect(args[try #require(args.firstIndex(of: "--max-budget-usd")) + 1] == "0.5")
        #expect(args[try #require(args.firstIndex(of: "--model")) + 1] == "haiku")
        #expect(args.suffix(2) == ["--", "Do the thing"])
    }

    @Test func withEvidenceFilesItGetsReadAndOtherwiseNoTools() throws {
        let with = try argv { $0.evidenceFiles = ["home.png"] }
        #expect(with.contains("--allowedTools") && with.contains("Read") && !with.contains("Bash"))
        let without = try argv()
        #expect(!without.contains("--allowedTools"))
        let tools = try #require(without.firstIndex(of: "--tools"))
        #expect(without[tools + 1] == "")
    }

    @Test func theSessionIsTheCallersSoTheLoggedArgvIsTheRunningOne() throws {
        func sessionID(_ args: [String]) throws -> String { args[try #require(args.firstIndex(of: "--session-id")) + 1] }
        #expect(try sessionID(argv()) == session)
        #expect(try argv() == argv(), "building twice gives the same argv")
        #expect(throws: AgentFailure.self) { try argv { $0.session = .none } }
        #expect(throws: AgentFailure.self) { try argv { $0.session = .start(proposed: "nope") } }
    }

    @Test func theModelIsWhatTheRequestSaysNotTheConfigs() throws {
        #expect(try !argv("model = \"opus\"\njudge_model = \"sonnet\"\n[tools]\navailable = [\"Read\"]\n").contains("--model"))
    }

    @Test func theLogShowsNeitherThePromptNorACredential() throws {
        let built = try ClaudeProvider(config: try Config.parse(claudeConfig)).invocation(for: judgeRequest())
        #expect(!built.displayArguments.contains("Do the thing") && !built.displayArguments.contains("--"))
        #expect(built.environment["AWS_SECRET"] == nil)
    }

    private func decode(_ lines: [String], exit status: ProcessExit = exit()) -> AgentDecoderResult {
        var d = ClaudeEnvelopeDecoder(maxRawBytes: 4096)
        for line in lines { _ = d.consume(line: line) }
        return d.finish(exit: status)
    }

    @Test func theEnvelopeIsUnwrappedWithItsCost() {
        let done = decode([#"{"type":"result","is_error":false,"result":"{\"x\":1}","total_cost_usd":0.0123}"#])
        #expect(done.outcome == .succeeded && done.answer == .text("{\"x\":1}") && done.usage?.costUSD == 0.0123)
        #expect(done.failure == nil)
        let pretty = decode(["{", #""type":"result","result":"hi""#, "}"])
        #expect(pretty.answer == .text("hi"), "an object spread over lines is still one object")
    }

    @Test func anErrorAnEmptyOutputAndAMissingResultAreFailuresNotAnswers() {
        let error = decode([#"{"type":"result","is_error":true,"result":"x"}"#])
        #expect(error.outcome == .failed && error.answer == nil && error.failure?.message == "claude reported an error")
        let budget = decode([#"{"type":"result","subtype":"error_max_budget_usd","is_error":true}"#])
        #expect(budget.failure?.kind == .budgetExceeded)
        for bad in [[], ["not json"], [#"{"type":"result"}"#]] {
            let r = decode(bad)
            #expect(r.outcome == .unknown && r.answer == nil && r.failure?.kind == .protocolError, "\(bad)")
        }
    }

    @Test func aLostLineMeansNoAnswer() {
        var d = ClaudeEnvelopeDecoder(maxRawBytes: 4096)
        _ = d.consume(oversizedPreview: #"{"type":"result","result":"#, totalBytes: 5 << 20)
        let r = d.finish(exit: exit())
        #expect(r.answer == nil && r.failure?.message.contains("line limit") == true)
    }
}
