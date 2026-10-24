import Foundation
import Testing

@testable import WorkbenchCore

private let tree = "/t/worktree"

private func coding(_ tweak: (inout AgentRequest) -> Void = { _ in }) -> AgentRequest {
    var r = AgentRequest(
        provider: .codex, prompt: "# Add a greeting\n\nDo it.", workingDirectory: URL(fileURLWithPath: tree),
        outputDirectory: URL(fileURLWithPath: "/t/prompts"), policy: .scopedCoding, spend: .timeoutOnly, purpose: .coding,
        environment: ["PATH": "/bin", "HOME": "/h", "GITHUB_TOKEN": "t", "ANTHROPIC_API_KEY": "a", "SECRET_FROM_ENV_PASS": "x"],
        limits: AgentLimits(timeout: 60))
    tweak(&r)
    return r
}

private func exit(_ termination: Termination = .exited(0), cause: StopCause = .natural, tail: String = "") -> ProcessExit {
    ProcessExit(
        termination: termination, cause: cause, durationMs: 1, escalatedToKill: false, sweptProcesses: 0,
        outputTruncated: false, lastLineAfterLimit: nil, stderrTail: tail, drainTimedOut: false)
}

private let started = #"{"type":"thread.started","thread_id":"01a16bbf-1eaf-77d0-b44a-b879ea1db69f"}"#
private let completed =
    #"{"type":"turn.completed","usage":{"input_tokens":30631,"cached_input_tokens":15104,"output_tokens":92}}"#

@Suite struct CodexCodingTests {
    private let provider = CodexProvider()

    @Test func codingCapabilities() {
        let caps = provider.capabilities
        #expect(caps.policies.contains(.scopedCoding) && caps.streamsActivity && caps.reportsUsage)
        #expect(!caps.hardDollarCap && !caps.confinesReads && caps.resume == .none)
        #expect(coding().validate(against: provider) == nil)
    }

    @Test func budgetGoalRefused() {
        let refusal = coding { $0.spend = .hardCap(1) }.validate(against: provider)
        #expect(refusal?.kind == .unsupportedCapability)
        #expect(refusal?.message.contains("spend_policy: timeout_only") == true, "\(String(describing: refusal?.message))")
    }

    @Test func codingInvocationIsHardened() throws {
        let args = try provider.invocation(for: coding()).arguments
        let expected = [
            "exec", "--json", "--color", "never", "--skip-git-repo-check", "--ephemeral", "--ignore-user-config",
            "--ignore-rules", "-c", "approval_policy=\"never\"", "-c", "sandbox_workspace_write.network_access=false",
            "-c", "sandbox_workspace_write.exclude_tmpdir_env_var=true", "-c", "sandbox_workspace_write.exclude_slash_tmp=true",
            "-s", "workspace-write", "-C", tree, "--", "# Add a greeting\n\nDo it.",
        ]
        #expect(args == expected, "\(args)")
        let joined = args.dropLast().joined(separator: " ")
        for banned in ["danger", "bypass", "full-auto", "read-only", "network_access=true", "-i "] {
            #expect(!joined.contains(banned), Comment(rawValue: "\(banned) in \(joined)"))
        }
        let shown = try provider.invocation(for: coding()).displayArguments
        #expect(!shown.contains("--") && !shown.contains { $0.contains("Add a greeting") }, "no prompt in the log")
    }

    @Test func codingRefusals() {
        for tweak: (inout AgentRequest) -> Void in [
            { $0.grants = ["Bash(ls:*)"] }, { $0.session = .start(proposed: "abc") },
            { $0.images = [URL(fileURLWithPath: "/p/one.png")] },
            { $0.workingDirectory = URL(string: "relative/tree") ?? $0.workingDirectory },
        ] {
            #expect(throws: AgentFailure.self) { try provider.invocation(for: coding(tweak)) }
        }
        // A coding purpose with a read-only policy (or the reverse) would start the wrong adapter path.
        let readOnly = coding { $0.policy = .readOnlyEvidence; $0.answerFile = URL(fileURLWithPath: "/t/prompts/answer.md") }
        #expect(readOnly.validate(against: provider)?.kind == .unsupportedCapability)
        #expect(coding { $0.purpose = .judge }.validate(against: provider)?.kind == .unsupportedCapability)
        // A resume is refused before it gets that far: the adapter keeps no conversation.
        let handle = AgentSessionHandle(provider: .codex, purpose: .coding, value: "x")
        #expect(coding { $0.session = .resume(handle) }.validate(against: provider)?.kind == .unsupportedCapability)
        #expect(coding { $0.provider = .claude }.validate(against: provider) != nil)
    }

    @Test func codingEnvironmentIsMinimal() throws {
        let environment = try provider.invocation(for: coding()).environment
        #expect(Set(environment.keys) == ["PATH", "HOME"], "\(environment.keys.sorted())")
        let wide = try provider.invocation(
            for: coding {
                $0.environment = [
                    "PATH": "/bin", "CODEX_HOME": "/c", "OPENAI_API_KEY": "k", "LC_ALL": "C", "ANTHROPIC_API_KEY": "a",
                    "GITHUB_TOKEN": "t", "SSH_AUTH_SOCK": "/s", "FAKE_CLAUDE": "x",
                ]
            }).environment
        #expect(Set(wide.keys) == ["PATH", "CODEX_HOME", "OPENAI_API_KEY", "LC_ALL"], "\(wide.keys.sorted())")
    }

    // MARK: Decoding

    private typealias Decoded = (items: [AgentActivity], result: AgentDecoderResult)

    private func decode(_ lines: [String], exit finish: ProcessExit = exit()) -> Decoded {
        var decoder = CodexCodingDecoder(purpose: .coding, maxRawBytes: 4096)
        var items: [AgentActivity] = []
        for line in lines { items += decoder.consume(line: line) }
        return (items, decoder.finish(exit: finish))
    }

    @Test func codingStreamIsDecoded() {
        let lines = [
            started, #"{"type":"turn.started"}"#,
            #"{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"I will edit a.txt."}}"#,
            #"{"type":"item.started","item":{"id":"item_1","type":"command_execution","#
                + #""command":"/bin/zsh -lc 'sed -i s/a/b/ a.txt'","status":"in_progress"}}"#,
            #"{"type":"item.completed","item":{"id":"item_1","type":"command_execution","#
                + #""command":"/bin/zsh -lc 'false'","exit_code":1,"status":"failed"}}"#,
            #"{"type":"item.completed","item":{"id":"item_2","type":"agent_message","text":"Done."}}"#, completed,
        ]
        let (items, result) = decode(lines)
        let handle = AgentSessionHandle(provider: .codex, purpose: .coding, value: "01a16bbf-1eaf-77d0-b44a-b879ea1db69f")
        #expect(items.first == .session(handle) && result.session == handle)
        #expect(items.contains(.text("I will edit a.txt.")) && items.contains(.text("Done.")))
        let ran = items.contains { item in
            if case .tool(let name, let summary) = item { return name == "shell" && summary.contains("sed -i") }
            return false
        }
        #expect(ran)
        #expect(items.contains { if case .diagnostic(let text) = $0 { text.contains("status 1") } else { false } })
        #expect(result.outcome == .succeeded && result.answer == .text("Done.") && result.failure == nil)
    }

    @Test func costStaysUnknown() {
        let (items, result) = decode([started, completed])
        let usage = result.usage
        #expect(usage?.inputTokens == 30631 && usage?.outputTokens == 92 && usage?.cachedInputTokens == 15104)
        #expect(usage?.costUSD == nil, "Codex reports no cost: unknown is never zero")
        #expect(items.contains(.usage(AgentUsage(inputTokens: 30631, outputTokens: 92, cachedInputTokens: 15104, costUSD: nil))))
    }

    @Test func unknownAndOversizedLines() {
        var decoder = CodexCodingDecoder(purpose: .coding, maxRawBytes: 64)
        let long = String(repeating: "q", count: 500)
        let odd = decoder.consume(line: #"{"type":"item.completed","item":{"type":"web_search","query":"\#(long)"}}"#)
        guard case .unknown(let provider, let raw)? = odd.first else {
            Issue.record("not kept: \(odd)")
            return
        }
        #expect(provider == .codex && raw.count <= 64, "bounded")
        #expect(decoder.consume(line: "not json at all") == [.unknown(provider: .codex, raw: "not json at all")])
        #expect(decoder.consume(line: #"{"type":"something.new"}"#).count == 1)
        let big = decoder.consume(oversizedPreview: "{\"type\":\"turn.compl", totalBytes: 9_000_000)
        #expect(big.count == 1)
        // The lost line may have been the end of the turn: with no turn.completed it is not a success.
        #expect(decoder.finish(exit: exit()).outcome != .succeeded)
    }

    @Test func successNeedsTurnCompleted() {
        #expect(decode([started, completed]).result.outcome == .succeeded)
        #expect(decode([started]).result.outcome == .unknown, "a stream that stops short is not a success")
        #expect(decode([started, completed], exit: exit(.exited(70))).result.outcome == .failed)
        #expect(decode([started, completed], exit: exit(.signaled(9))).result.outcome == .failed)
        #expect(decode([started, completed], exit: exit(.exited(0), cause: .timedOut)).result.outcome == .failed)
        #expect(decode([started, completed], exit: exit(.exited(0), cause: .stopped)).result.outcome == .failed)
        let failure = #"{"type":"turn.failed","error":{"message":"context window exceeded"}}"#
        let failed = decode([started, failure], exit: exit(.exited(1)))
        #expect(failed.result.outcome == .failed && failed.result.failure?.message == "context window exceeded")
        let capacity = decode([started, "ERROR: Selected model is at capacity right now"], exit: exit(.exited(1)))
        #expect(capacity.result.failure?.kind == .capacity && capacity.result.failure?.retry == .transient)
        let reconnect = decode([started, #"{"type":"error","message":"reconnecting"}"#, completed])
        #expect(reconnect.result.outcome == .succeeded, "a transient error before a completed turn does not fail it")
    }

    @Test func probeFixturesReplay() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        let folder = root.appendingPathComponent("docs/plan/P9-probes/fixtures")
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasPrefix("codex-ws-hardened-") && $0.hasSuffix(".stdout") }.sorted()
        try #require(!files.isEmpty, "the probe fixtures are in the repository")
        for name in files {
            let text = try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
            let (items, result) = decode(text.split(separator: "\n").map(String.init))
            #expect(result.outcome == .succeeded, Comment(rawValue: "\(name): \(result.outcome)"))
            #expect(result.session?.provider == .codex && result.usage?.inputTokens != nil && result.usage?.costUSD == nil)
            let unknown = items.contains { if case .unknown = $0 { true } else { false } }
            #expect(!unknown, Comment(rawValue: "\(name) has an unknown line"))
        }
    }
}

// MARK: Through the runner, with a fake codex

@Suite(.processGate) struct CodexCodingRunnerTests {
    private func fake(_ body: String) throws -> (URL, URL) {
        let dir = Scratch.url("codex-coding", ext: "d")
        let work = dir.appendingPathComponent("worktree")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("codex")
        try "#!/bin/sh\n\(body)\n".write(to: script, atomically: true, encoding: .utf8)
        chmod(script.path, 0o755)
        return (script, work)
    }

    private func run(
        _ script: URL, _ work: URL, timeout: TimeInterval = 20, stopWhenExists: URL? = nil
    ) async throws -> AgentCompletion {
        let request = coding {
            $0.workingDirectory = work
            $0.outputDirectory = work.deletingLastPathComponent()
            $0.environment = ["PATH": "/usr/bin:/bin"]
            $0.limits = AgentLimits(timeout: timeout, killGrace: 1)
        }
        let execution = try AgentRunner.start(provider: CodexProvider(executable: script.path), request: request)
        if let stopWhenExists {
            // Stopped once the fake says it has started its child, not after a guess about how long that takes.
            Task {
                for _ in 0..<600 where !FileManager.default.fileExists(atPath: stopWhenExists.path) {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                execution.stop()
            }
        }
        return await execution.completion
    }

    @Test func codexCodingFake() async throws {
        let (script, work) = try fake(
            """
            echo '\(started)'
            echo hello > created.txt
            echo '{"type":"item.completed","item":{"id":"i","type":"agent_message","text":"wrote created.txt"}}'
            echo '\(completed)'
            """)
        let done = try await run(script, work)
        #expect(done.succeeded, "\(done.failure.map(\.message) ?? "") \(done.process)")
        let created = work.appendingPathComponent("created.txt")
        #expect(FileManager.default.fileExists(atPath: created.path), "it works in the worktree")
        #expect(done.session?.provider == .codex && done.session?.purpose == .coding)
        #expect(done.summary == "wrote created.txt" && done.usage?.costUSD == nil)
    }

    @Test func aStopEndsTheChildAndItsDescendants() async throws {
        let (script, work) = try fake("echo '\(started)'\nsleep 300 &\necho $! > \"$PWD/child.pid\"\nwait")
        let done = try await run(script, work, stopWhenExists: work.appendingPathComponent("child.pid"))
        #expect(done.failure?.kind == .cancellation && !done.succeeded)
        let text = try String(contentsOf: work.appendingPathComponent("child.pid"), encoding: .utf8)
        let pid = try #require(Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        var gone = false
        for _ in 0..<100 where !gone {
            gone = kill(pid, 0) != 0
            if !gone { try await Task.sleep(nanoseconds: 50_000_000) }
        }
        #expect(gone, "no child is left behind")
    }

    @Test func aMissingWorktreeFailsBeforeAnyProcess() throws {
        let (script, work) = try fake("echo '\(started)'")
        let request = coding {
            $0.workingDirectory = work.appendingPathComponent("not-there")
            $0.environment = ["PATH": "/usr/bin:/bin"]
        }
        let provider = CodexProvider(executable: script.path)
        #expect(throws: AgentFailure.self) { try AgentRunner.start(provider: provider, request: request) }
    }

    @Test func theDeadlineEndsAHungTurn() async throws {
        let (script, work) = try fake("echo '\(started)'\nsleep 300")
        let done = try await run(script, work, timeout: 1)
        #expect(done.failure?.kind == .timeout && !done.succeeded)
    }
}
