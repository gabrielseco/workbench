import Foundation
import Testing

@testable import WorkbenchCore

private let gateway = OpencodeProvider.Gateway(baseURL: "https://gw.example/v1")
private let forwarder = OpencodeProvider.Forwarder(baseURL: "http://127.0.0.1:4100/v1")
private let userDirs = OpencodeSandbox.UserDirectories(
    temp: URL(fileURLWithPath: "/private/var/folders/ab/cd/T"), cache: URL(fileURLWithPath: "/private/var/folders/ab/cd/C"))

/// A folder with a fake `opencode` on its PATH, and the worktree and output directories a request names.
private struct Fixture {
    let root: URL
    let bin: URL
    let worktree: URL
    let output: URL

    init() throws {
        let base = try #require(realpath(NSTemporaryDirectory(), nil).map { String(cString: $0) })
        root = URL(fileURLWithPath: base).appendingPathComponent("oc-provider-\(UUID().uuidString)")
        bin = root.appendingPathComponent("bin")
        worktree = root.appendingPathComponent("wt")
        output = root.appendingPathComponent("out")
        for dir in [bin, worktree, output] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        let exe = bin.appendingPathComponent("opencode")
        try "#!/bin/sh\nexit 0\n".write(to: exe, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    func request(_ policy: AgentPolicy = .readOnlyEvidence, tweak: (inout AgentRequest) -> Void = { _ in }) -> AgentRequest {
        var r = AgentRequest(
            provider: .opencode, model: "sonnet-claude", prompt: "Review the diff.", workingDirectory: worktree,
            outputDirectory: output, policy: policy, spend: .timeoutOnly,
            purpose: policy == .scopedCoding ? .coding : .review,
            environment: [
                "PATH": "\(bin.path):/usr/bin:/bin", "HOME": "/h", "LANG": "en_US.UTF-8", "LC_ALL": "C",
                "LITELLM_API_KEY": "real-key",
                "GITHUB_TOKEN": "gh", "OPENAI_API_KEY": "oa", "ANTHROPIC_API_KEY": "an", "CODEX_HOME": "/c",
            ],
            limits: AgentLimits(timeout: 60))
        tweak(&r)
        return r
    }
}

private func exit(_ termination: Termination = .exited(0), cause: StopCause = .natural, tail: String = "") -> ProcessExit {
    ProcessExit(
        termination: termination, cause: cause, durationMs: 1, escalatedToKill: false, sweptProcesses: 0,
        outputTruncated: false, lastLineAfterLimit: nil, stderrTail: tail, drainTimedOut: false)
}

private func refusal(_ provider: OpencodeProvider, _ request: AgentRequest) -> AgentFailure? {
    do {
        _ = try provider.invocation(for: request)
        return nil
    } catch { return error as? AgentFailure }
}

@Suite struct OpencodeProviderInvocationTests {
    private func provider(
        _ forwarder: OpencodeProvider.Forwarder? = nil, dirs: OpencodeSandbox.UserDirectories? = userDirs
    ) -> OpencodeProvider {
        OpencodeProvider(gateway: gateway, forwarder: forwarder, userDirectories: dirs, home: URL(fileURLWithPath: "/h"))
    }

    @Test func aReadOnlyTurnRunsOpencodeDirectlyWithThePromptAfterTheDashes() throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        let inv = try provider().invocation(for: f.request())
        #expect(inv.executable == f.bin.appendingPathComponent("opencode").path)
        let expected = ["run", "--standalone", "--format", "json", "--archived", "-m", "gateway/sonnet-claude", "--"]
        #expect(inv.arguments == expected + ["Review the diff."])
        #expect(!inv.arguments.contains("--auto"), "an ask is approved by --auto; every rule is an explicit deny instead")
        #expect(!inv.displayArguments.contains("Review the diff.") && inv.displayArguments.last == "gateway/sonnet-claude")
    }

    @Test func aPromptThatStartsWithDashesIsStillThePrompt() throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        let args = try provider().invocation(for: f.request { $0.prompt = "--auto --share is what I want" }).arguments
        let dashes = try #require(args.firstIndex(of: "--"))
        #expect(args[(dashes + 1)...] == ["--auto --share is what I want"], "after `--`, opencode reads it as the message")
        #expect(!args[..<dashes].contains("--auto"))
    }

    @Test func theChildSeesOnlyTheMinimalEnvironmentTheKeyAndItsOwnDirectories() throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        let env = try provider().invocation(for: f.request()).environment
        #expect(env["LITELLM_API_KEY"] == "real-key" && env["HOME"] == "/h")
        #expect(env["LANG"] == "en_US.UTF-8" && env["LC_ALL"] == "C")
        for leaked in ["GITHUB_TOKEN", "OPENAI_API_KEY", "ANTHROPIC_API_KEY", "CODEX_HOME"] {
            #expect(env[leaked] == nil, "\(leaked) is another provider's or the project's, not this run's")
        }
        #expect(env["OPENCODE_DISABLE_PROJECT_CONFIG"] == "1")
        #expect(env["OPENCODE_CONFIG"]?.hasSuffix("/opencode/opencode.json") == true)
        #expect(env["TMPDIR"]?.hasPrefix(f.output.path) == true && env["XDG_DATA_HOME"]?.hasPrefix(f.output.path) == true)
    }

    @Test func aReadOnlyTurnWritesAConfigWithNoShellAndNoProfile() throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        _ = try provider().invocation(for: f.request())
        let layout = OpencodeRunLayout(root: f.output.appendingPathComponent("opencode"))
        let written = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: layout.configFile)) as? [String: Any])
        let rules = try #require(written["permission"] as? [String: Any])
        #expect(rules["edit"] as? String == "deny" && (rules["bash"] as? [String: String]) == ["*": "deny"])
        #expect(written["model"] as? String == "gateway/sonnet-claude")
        #expect(!FileManager.default.fileExists(atPath: layout.profileFile.path), "a read-only turn is not wrapped")
    }

    @Test func aCodingTurnIsWrappedInTheSandboxWithTheWorktreeAndTheForwarder() throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        let inv = try provider(forwarder).invocation(for: f.request(.scopedCoding))
        #expect(inv.executable == "/usr/bin/sandbox-exec")
        let layout = OpencodeRunLayout(root: f.output.appendingPathComponent("opencode"))
        #expect(inv.arguments.prefix(3) == ["-f", layout.profileFile.path, f.bin.appendingPathComponent("opencode").path])
        #expect(inv.arguments.suffix(3) == ["-m", "gateway/sonnet-claude", "--"] || inv.arguments.contains("--"))
        let profile = try String(contentsOf: layout.profileFile, encoding: .utf8)
        #expect(profile.contains("(subpath \"\(f.worktree.path)\")") && profile.contains("(deny network*)"))
        let ownLogin = "(deny file-read* (subpath \"/h/.local/share/opencode\"))"
        #expect(profile.contains(ownLogin), "the person's own login is not readable")
        let config = try #require(String(data: Data(contentsOf: layout.configFile), encoding: .utf8))
        #expect(config.contains("http://127.0.0.1:4100/v1") && !config.contains("gw.example"), "the model is reached through the forwarder")
        #expect(config.contains("\"git push*\"") && config.contains("\"edit\" : \"allow\""))
    }

    @Test func theRealKeyNeverReachesASandboxedChildOrTheFiles() throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        let inv = try provider(forwarder).invocation(for: f.request(.scopedCoding))
        #expect(inv.environment["LITELLM_API_KEY"] == "forwarder", "the forwarder adds the real key; `env` prints this")
        #expect(!inv.environment.values.contains("real-key"))
        let layout = OpencodeRunLayout(root: f.output.appendingPathComponent("opencode"))
        for file in [layout.configFile, layout.profileFile] {
            #expect(try !String(contentsOf: file, encoding: .utf8).contains("real-key"))
        }
        let readOnly = try provider(forwarder).invocation(for: f.request())
        #expect(readOnly.environment["LITELLM_API_KEY"] == "forwarder", "with a forwarder every turn goes through it")
    }

    @Test func aCodingTurnWithoutTheSandboxOrTheForwarderIsRefusedNotRunUnconfined() throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        let noForwarder = try #require(refusal(provider(nil), f.request(.scopedCoding)))
        #expect(noForwarder.kind == .unsupportedCapability && noForwarder.message.contains("cannot confine a shell"))
        let noSandbox = try #require(refusal(provider(forwarder, dirs: nil), f.request(.scopedCoding)))
        #expect(noSandbox.kind == .unsupportedCapability && noSandbox.retry == .afterFix)
        #expect(!FileManager.default.fileExists(atPath: f.output.appendingPathComponent("opencode").path), "nothing was prepared")
        #expect(refusal(provider(forwarder, dirs: nil), f.request()) == nil, "a read-only turn needs no sandbox")
    }

    @Test func aRequestOpencodeCannotHonourIsRefusedBeforeAnythingIsWritten() throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        let cases: [(String, (inout AgentRequest) -> Void)] = [
            ("dollar cap", { $0.spend = .hardCap(1) }),
            ("resume", { $0.session = .start(proposed: nil) }),
            ("grants", { $0.grants = ["Bash(git:*)"] }),
            ("images", { $0.images = [URL(fileURLWithPath: "/p/a.png")] }),
            ("effort", { $0.reasoningEffort = "high" }),
            ("readable checkouts", { $0.readDirectories = [URL(fileURLWithPath: "/other")] }),
            ("no model", { $0.model = nil }),
            ("relative checkout", { $0.workingDirectory = URL(string: "relative/wt")! }),
            ("no key", { $0.environment["LITELLM_API_KEY"] = nil }),
            ("no opencode", { $0.environment["PATH"] = "/nonexistent" }),
            ("model that is a flag", { $0.model = "-m" }),
        ]
        for (name, tweak) in cases {
            let failure = try #require(refusal(provider(), f.request(tweak: tweak)), "\(name) should be refused")
            #expect(failure.retry == .afterFix, "\(name): \(failure.message)")
        }
        #expect(!FileManager.default.fileExists(atPath: f.output.appendingPathComponent("opencode").path))
    }

    @Test func theCapabilitiesSayWhatWasProbedAndNothingMore() {
        let caps = provider().capabilities
        #expect(caps.policies == [.readOnlyEvidence, .scopedCoding] && caps.resume == .none)
        #expect(caps.reportsUsage && caps.streamsActivity)
        #expect(caps.confinesReads(for: .readOnlyEvidence), "no shell, and external_directory is denied")
        #expect(!caps.confinesReads(for: .scopedCoding), "a coding turn has a shell; the sandbox refuses writes, not reads")
        #expect(!caps.hardDollarCap && !caps.imageAttachments && !caps.structuredOutput)
        #expect(provider().id == .opencode)
    }
}

@Suite struct OpencodeDecoderTests {
    private func decode(
        _ lines: [String], exit: ProcessExit = exit(), purpose: AgentSessionHandle.Purpose = .review
    ) -> (activity: [AgentActivity], result: AgentDecoderResult) {
        var decoder = OpencodeDecoder(purpose: purpose, maxRawBytes: 4096)
        var activity: [AgentActivity] = []
        for line in lines { activity += decoder.consume(line: line) }
        return (activity, decoder.finish(exit: exit))
    }

    private let sid = "ses_1"
    private func start() -> String { #"{"type":"step_start","sessionID":"ses_1","part":{"type":"step-start"}}"# }
    private func text(_ t: String) -> String { #"{"type":"text","sessionID":"ses_1","part":{"type":"text","text":"\#(t)"}}"# }
    private func finish(_ reason: String, cost: Double = 0.02, input: Int = 100, output: Int = 10, cached: Int = 0) -> String {
        let tokens = #"{"input":\#(input),"output":\#(output),"reasoning":0,"cache":{"read":\#(cached),"write":0}}"#
        let part = #"{"type":"step-finish","reason":"\#(reason)","cost":\#(cost),"tokens":\#(tokens)}"#
        return #"{"type":"step_finish","sessionID":"ses_1","part":\#(part)}"#
    }
    private func tool(_ name: String, _ input: String, status: String = "completed", error: String? = nil) -> String {
        let tail = error.map { #","error":"\#($0)""# } ?? #","output":"done""#
        let state = #"{"status":"\#(status)","input":\#(input)\#(tail)}"#
        return #"{"type":"tool_use","sessionID":"ses_1","part":{"type":"tool","tool":"\#(name)","state":\#(state)}}"#
    }

    @Test func aTurnThatEndsInStopSucceedsWithItsLastTextAsTheAnswer() {
        let lines = [start(), text("first"), finish("tool-calls"), start(), text("All good."), finish("stop")]
        let (activity, result) = decode(lines)
        #expect(result.outcome == .succeeded && result.answer == .text("All good."))
        #expect(result.session == AgentSessionHandle(provider: .opencode, purpose: .review, value: "ses_1"))
        #expect(activity.filter { if case .session = $0 { true } else { false } }.count == 1, "the session is announced once")
        #expect(activity.contains(.text("All good.")))
    }

    @Test func costAndTokensAreSummedOverTheSteps() {
        let steps = [
            finish("tool-calls", cost: 0.01, input: 100, output: 5, cached: 40), finish("stop", cost: 0.02, input: 50, output: 7),
        ]
        let (_, result) = decode(steps)
        #expect(result.usage == AgentUsage(inputTokens: 150, outputTokens: 12, cachedInputTokens: 40, costUSD: 0.03))
    }

    @Test func noStepMeansUsageIsUnknownNotZero() {
        let (_, result) = decode([text("hi")])
        #expect(result.usage == nil)
    }

    @Test func aStreamThatStopsAfterAToolCallIsNotASuccessEvenWithExitZero() {
        let (_, result) = decode([start(), tool("shell", #"{"command":"ls"}"#), finish("tool-calls")])
        #expect(result.outcome != .succeeded, "a step that asked for a tool is not the end of the turn")
    }

    @Test func aStopWithAKilledProcessIsFailedNotSucceeded() {
        let killed = exit(.signaled(SIGKILL), cause: .timedOut)
        #expect(decode([text("done"), finish("stop")], exit: killed).result.outcome == .failed)
        #expect(decode([text("done"), finish("stop")], exit: exit(.exited(1))).result.outcome == .failed)
    }

    @Test func aLostLongLineMeansTheTurnCannotBeCalledASuccess() {
        var decoder = OpencodeDecoder(purpose: .review, maxRawBytes: 4096)
        _ = decoder.consume(line: text("x"))
        _ = decoder.consume(line: finish("stop"))
        let lost = decoder.consume(oversizedPreview: #"{"type":"step_fin"#, totalBytes: 9_000_000)
        #expect(lost.contains { if case .diagnostic = $0 { true } else { false } })
        #expect(decoder.finish(exit: exit()).outcome != .succeeded)
    }

    @Test func aRefusedToolCallIsADenialWithItsCommandAndNotAFailureOfTheTurn() {
        let denied = tool("shell", #"{"command":"git push origin main"}"#, status: "error", error: "Permission denied: shell")
        let (activity, result) = decode([start(), denied, text("It was refused."), finish("stop")])
        #expect(activity.contains(.permissionDenied(tool: "shell", input: "git push origin main")))
        #expect(result.permissionDenials == [AgentDenial(tool: "shell", input: "git push origin main")])
        #expect(result.permissionDenialCount == 1 && result.outcome == .succeeded)
    }

    @Test func aToolThatFailedForAnotherReasonIsADiagnosticNotADenial() {
        let failed = tool("shell", #"{"command":"false"}"#, status: "error", error: "exit status 1")
        let (activity, result) = decode([failed, finish("stop")])
        #expect(result.permissionDenialCount == 0)
        #expect(activity.contains { if case .diagnostic(let d) = $0 { d.contains("shell failed") } else { false } })
    }

    @Test func denialsAreBoundedAtAHundredButAllCounted() {
        let denied = tool("write", #"{"path":"/x"}"#, status: "error", error: "Permission denied: external_directory")
        let (_, result) = decode(Array(repeating: denied, count: 130) + [finish("stop")])
        #expect(result.permissionDenials.count == 100 && result.permissionDenialCount == 130)
    }

    @Test func aToolCallIsReportedWithItsCommandOrPathTrimmed() {
        let long = String(repeating: "a", count: 500)
        let (activity, _) = decode([tool("shell", #"{"command":"\#(long)"}"#), tool("edit", #"{"path":"/w/a.swift"}"#)])
        #expect(activity.contains(.tool(name: "shell", summary: String(long.prefix(300)))))
        #expect(activity.contains(.tool(name: "edit", summary: "/w/a.swift")))
    }

    @Test func aGatewayWithNoCreditIsAFailureThatNeedsAFixNotARetry() throws {
        let message = "litellm.BadRequestError: AnthropicException - Your credit balance is too low to access the Anthropic API."
        let line = #"{"type":"error","sessionID":"ses_1","error":{"type":"provider.invalid-request","message":"\#(message)"}}"#
        let (_, result) = decode([start(), line], exit: exit(.exited(1)))
        let failure = try #require(result.failure)
        #expect(result.outcome == .failed && failure.kind == .budgetExceeded && failure.retry == .afterFix)
        #expect(failure.message.contains("credit"))
    }

    @Test(arguments: [
        ("401 Unauthorized: invalid api key", AgentFailure.Kind.authOrConfig, AgentRetry.afterFix),
        ("429 rate limit reached", .capacity, .transient),
        ("Overloaded", .capacity, .transient),
        ("ExceededBudget: key over its max_budget", .budgetExceeded, .afterFix),
        ("something nobody planned for", .process, .never),
    ])
    func aProviderErrorIsClassifiedByWhatThePersonCanDoAboutIt(
        message: String, kind: AgentFailure.Kind, retry: AgentRetry
    ) throws {
        let line = #"{"type":"error","error":{"type":"unknown","message":"\#(message)"}}"#
        let failure = try #require(decode([line], exit: exit(.exited(1))).result.failure)
        #expect(failure.kind == kind && failure.retry == retry)
    }

    @Test func anErrorBeforeAStopThatTheTurnRecoveredFromIsNotTheEnd() {
        let line = #"{"type":"error","error":{"type":"unknown","message":"connection reset"}}"#
        let (_, result) = decode([line, start(), text("recovered"), finish("stop")])
        #expect(result.outcome == .succeeded && result.failure == nil)
    }

    @Test func aRetryTheGatewayCausedIsReportedAndDoesNotFailATurnThatThenEndsInStop() {
        let error = #"{"type":"provider.internal","message":"Service Unavailable","status":503}"#
        let retry = #"{"type":"retry","sessionID":"ses_1","attempt":2,"error":\#(error)}"#
        let (activity, result) = decode([start(), retry, start(), text("ok"), finish("stop")])
        #expect(activity.contains(.diagnostic("retry 2: Service Unavailable")))
        #expect(!activity.contains { if case .unknown = $0 { true } else { false } }, "a retry is a known event")
        #expect(result.outcome == .succeeded && result.failure == nil)
    }

    @Test func aStopFollowedByAnErrorIsAFailureWithItsClassification() throws {
        let error = #"{"type":"error","error":{"type":"unknown","message":"429 rate limit reached"}}"#
        let (_, result) = decode([text("done"), finish("stop"), error], exit: exit())
        #expect(result.outcome == .failed, "the error is the end of the turn, whatever came before it")
        let failure = try #require(result.failure)
        #expect(failure.kind == .capacity && failure.retry == .transient)
    }

    @Test func aStepThatBeganAfterAStopAndNeverFinishedMeansTheTurnDidNotEndThere() {
        let (_, result) = decode([text("done"), finish("stop"), start()], exit: exit())
        #expect(result.outcome != .succeeded)
        let twoStops = [start(), text("done"), finish("stop"), start(), text("more"), finish("stop")]
        #expect(decode(twoStops).result.outcome == .succeeded, "the last step is what counts")
    }

    @Test func tokenCountsThatWouldOverflowStopAtTheLargestIntAndNegativeOnesAreIgnored() {
        let steps = [
            finish("tool-calls", input: Int.max, output: 1), finish("tool-calls", input: 1, output: -5),
            finish("stop", input: 7, output: 1),
        ]
        let (_, result) = decode(steps)
        #expect(result.outcome == .succeeded)
        #expect(result.usage?.inputTokens == Int.max && result.usage?.outputTokens == 2)
    }

    @Test func aCostThatIsNotFiniteOrNegativeIsIgnoredSoTheLogCanAlwaysEncodeIt() throws {
        func step(_ cost: String) -> String {
            let tokens = #"{"input":1,"output":1}"#
            return #"{"type":"step_finish","sessionID":"s","part":{"reason":"tool-calls","cost":\#(cost),"tokens":\#(tokens)}}"#
        }
        let costs = ["0.01", "1e999", "-3", "1e308", "1e308"].map(step)
        let (_, result) = decode(costs + [finish("stop", cost: 0.02)])
        let cost = try #require(result.usage?.costUSD)
        #expect(cost.isFinite && cost >= 0.03)
        _ = try JSONEncoder().encode(result.usage)
    }

    // A stream the real binary produced (a read-only turn through the gateway, which answered 503 once and was retried), trimmed of
    // machine ids and paths. The hand-written streams above are only as right as what was known when they were written.
    // swiftlint:disable line_length
    private static let recorded = [
        #"{"type":"step_start","sessionID":"ses_ded43ea57ffeqJ77bD2kl9OOW6","part":{"sessionID":"ses_ded43ea57ffeqJ77bD2kl9OOW6","type":"step-start"}}"#,
        #"{"type":"retry","sessionID":"ses_ded43ea57ffeqJ77bD2kl9OOW6","attempt":2,"error":{"type":"provider.internal","message":"Service Unavailable, the authentication database is temporarily unreachable. Please retry shortly.","status":503}}"#,
        #"{"type":"tool_use","sessionID":"ses_ded43ea57ffeqJ77bD2kl9OOW6","part":{"sessionID":"ses_ded43ea57ffeqJ77bD2kl9OOW6","type":"tool","tool":"execute","state":{"status":"completed","input":{"code":"return await search(\"shell bash run command\")"},"output":"{\"items\":[{\"path\":\"tools.automation.create\",\"description\":\"C"}}}"#,
        #"{"type":"tool_use","sessionID":"ses_ded43ea57ffeqJ77bD2kl9OOW6","part":{"sessionID":"ses_ded43ea57ffeqJ77bD2kl9OOW6","type":"tool","tool":"read","state":{"status":"completed","input":{"path":"/w/notes.txt"},"output":"Read file /w/notes.txt, lines 1-1\n1: alpha beta"}}}"#,
        #"{"type":"step_finish","sessionID":"ses_ded43ea57ffeqJ77bD2kl9OOW6","part":{"sessionID":"ses_ded43ea57ffeqJ77bD2kl9OOW6","type":"step-finish","reason":"tool-calls","cost":0.013182,"tokens":{"input":5726,"output":173,"reasoning":0,"cache":{"read":0,"write":0}}}}"#,
        #"{"type":"step_start","sessionID":"ses_ded43ea57ffeqJ77bD2kl9OOW6","part":{"sessionID":"ses_ded43ea57ffeqJ77bD2kl9OOW6","type":"step-start"}}"#,
        #"{"type":"text","sessionID":"ses_ded43ea57ffeqJ77bD2kl9OOW6","part":{"sessionID":"ses_ded43ea57ffeqJ77bD2kl9OOW6","type":"text","text":"**notes.txt** contains one line: `alpha beta`.\n\n**Running `ls`:** I couldn't run it. I have no shell or bash tool in this session. My tools are file read, glob, grep, skill loading, and the Code Mode "}}"#,
        #"{"type":"step_finish","sessionID":"ses_ded43ea57ffeqJ77bD2kl9OOW6","part":{"sessionID":"ses_ded43ea57ffeqJ77bD2kl9OOW6","type":"step-finish","reason":"stop","cost":0.022858,"tokens":{"input":10384,"output":209,"reasoning":0,"cache":{"read":0,"write":0}}}}"#,
    ]
    // swiftlint:enable line_length

    @Test func aRealRecordedStreamDecodesToWhatItDid() throws {
        let (activity, result) = decode(Self.recorded)
        #expect(result.outcome == .succeeded && result.failure == nil && result.permissionDenialCount == 0)
        #expect(result.session?.value == "ses_ded43ea57ffeqJ77bD2kl9OOW6")
        #expect(result.usage?.inputTokens == 5726 + 10384 && result.usage?.outputTokens == 173 + 209)
        let cost = try #require(result.usage?.costUSD)
        #expect(abs(cost - (0.013182 + 0.022858)) < 1e-9)
        #expect(activity.contains(.tool(name: "read", summary: "/w/notes.txt")))
        let retried = activity.contains {
            if case .diagnostic(let d) = $0 { d.hasPrefix("retry 2: Service Unavailable") } else { false }
        }
        let unknown = activity.contains { if case .unknown = $0 { true } else { false } }
        #expect(retried && !unknown, "every event of a real stream is understood")
        guard case .text(let answer)? = result.answer else { Issue.record("no text answer"); return }
        #expect(answer.contains("alpha beta"))
    }

    @Test func aProcessThatSaidNothingButFailedKeepsWhatStderrSaid() throws {
        let (_, result) = decode([], exit: exit(.exited(1), tail: "Standalone server exited before reporting readiness"))
        #expect(result.outcome == .unknown)
        #expect(try #require(result.failure).message.contains("before reporting readiness"))
        #expect(decode([], exit: exit(.exited(1))).result.failure == nil, "no stderr, nothing to say")
    }

    @Test func aLineItDoesNotUnderstandIsKeptNotDropped() {
        let (activity, _) = decode(["not json", #"{"type":"something_new","x":1}"#])
        let unknown = activity.filter { if case .unknown(.opencode, _) = $0 { true } else { false } }
        #expect(unknown.count == 2)
    }

    @Test func theSessionHandleCarriesThePurposeSoAJudgeCannotResumeTheCoder() {
        let (_, result) = decode([start(), finish("stop")], purpose: .coding)
        #expect(result.session?.purpose == .coding && result.session?.provider == .opencode)
    }
}
