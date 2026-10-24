import Foundation
import Testing

@testable import WorkbenchCore

private let folder = URL(fileURLWithPath: "/t/pr-review")

private func request(_ tweak: (inout AgentRequest) -> Void = { _ in }) -> AgentRequest {
    var r = AgentRequest(
        provider: .codex, prompt: PRReview.instruction(brief: "/t/pr-review/brief.md"),
        workingDirectory: URL(fileURLWithPath: "/t/pr-review/round-1.tree"), outputDirectory: folder,
        policy: .readOnlyEvidence, spend: .timeoutOnly, purpose: .review,
        environment: ["PATH": "/bin", "HOME": "/h", "GITHUB_TOKEN": "t"], limits: AgentLimits(timeout: 60),
        answerFile: folder.appendingPathComponent("round-1.findings.md"))
    tweak(&r)
    return r
}

private func exit(_ termination: Termination = .exited(0), cause: StopCause = .natural, tail: String = "") -> ProcessExit {
    ProcessExit(
        termination: termination, cause: cause, durationMs: 1, escalatedToKill: false, sweptProcesses: 0,
        outputTruncated: false, lastLineAfterLimit: nil, stderrTail: tail, drainTimedOut: false)
}

@Suite struct CodexProviderInvocationTests {
    private let provider = CodexProvider()

    @Test func theCommandLineCarriesAPointerNotTheReview() throws {
        let args = try provider.invocation(for: request()).arguments
        #expect(args.starts(with: ["exec", "-s", "read-only", "-C", "/t/pr-review/round-1.tree"]))
        #expect(args.contains("--ephemeral") && args.contains("-o") && args.contains("/t/pr-review/round-1.findings.md"))
        #expect(args.last?.contains("/t/pr-review/brief.md") == true)
        #expect(!args.contains("-"), "stdin is /dev/null: the prompt is not read from it")
        #expect(!args.contains("danger-full-access") && !args.contains("workspace-write"))
    }

    @Test func theUsersRulesAndApprovalSettingsCannotRunAnythingOutsideTheSandbox() throws {
        let args = try provider.invocation(for: request { $0.images = [URL(fileURLWithPath: "/p/one.png")] }).arguments
        #expect(args.contains("--ignore-rules"))
        let at = try #require(args.firstIndex(of: "-c"))
        #expect(args[at + 1] == "approval_policy=\"never\"", "\(args)")
        #expect(try #require(args.firstIndex(of: "--ignore-rules")) < args.firstIndex(of: "--")!, "options before the prompt")
        #expect(!args.contains("--ignore-user-config"), "the user's model and login settings still apply")
    }

    @Test func theBriefPointerFollowsTheImagesAfterADoubleDash() throws {
        // `codex exec -i` takes a list of files: a prompt right after it is read as one more image and Codex
        // exits with "No prompt provided via stdin".
        let images = ["/p/one.png", "/p/two.png"].map { URL(fileURLWithPath: $0) }
        let args = try provider.invocation(for: request { $0.images = images }).arguments
        #expect(args.last?.contains("/t/pr-review/brief.md") == true)
        #expect(args[args.count - 2] == "--", "\(args)")
        #expect(args.filter { $0 == "-i" }.count == 2)
        #expect(try #require(args.firstIndex(of: "--")) > args.lastIndex(of: "-i") ?? 0, "every image comes before the --")
    }

    @Test func theLogShowsNeitherThePromptNorWhatFollowsIt() throws {
        let built = try provider.invocation(for: request())
        #expect(!built.displayArguments.contains("--") && !built.displayArguments.contains(request().prompt))
        #expect(built.answerFile?.lastPathComponent == "round-1.findings.md")
    }

    @Test func codexSeesTheMinimalEnvironmentAndItsOwnLogin() {
        let parent = [
            "PATH": "/bin", "HOME": "/h", "CODEX_HOME": "/c", "OPENAI_API_KEY": "k", "LC_ALL": "C", "GITHUB_TOKEN": "t",
            "ANTHROPIC_API_KEY": "a", "AWS_SECRET_ACCESS_KEY": "s", "SSH_AUTH_SOCK": "/s",
        ]
        #expect(Set(CodexProvider.environment(from: parent).keys) == ["PATH", "HOME", "CODEX_HOME", "OPENAI_API_KEY", "LC_ALL"])
    }

    @Test func whatCodexCannotDoIsRefusedNotBent() throws {
        let p = provider
        #expect(request().validate(against: p) == nil)
        #expect(request { $0.spend = .hardCap(1) }.validate(against: p)?.kind == .unsupportedCapability, "no dollar cap")
        #expect(request { $0.provider = .claude }.validate(against: p) != nil)
        for tweak: (inout AgentRequest) -> Void in [
            { $0.model = "gpt" }, { $0.grants = ["Bash(ls:*)"] }, { $0.session = .start(proposed: nil) },
            { $0.answerFile = nil }, { $0.answerFile = URL(fileURLWithPath: "/t/pr-review/round-1.tree/answer.md") },
            { $0.answerFile = URL(fileURLWithPath: "/elsewhere/answer.md") },
        ] {
            #expect(throws: AgentFailure.self) { try p.invocation(for: request(tweak)) }
        }
    }

    @Test func theLimitsOfThisProviderAreStatedNotHidden() {
        let caps = provider.capabilities
        #expect(!caps.hardDollarCap && !caps.confinesReads && caps.imageAttachments && caps.resume == .none)
        #expect(caps.policies == [.readOnlyEvidence, .scopedCoding])
    }
}

@Suite struct CodexDecoderTests {
    private func answer(_ text: String?) throws -> URL {
        let url = Scratch.url("codex", ext: "md")
        if let text { try text.write(to: url, atomically: true, encoding: .utf8) }
        return url
    }

    @Test func anAnswerFileIsTheAnswerWhateverTheStreamSaid() throws {
        let url = try answer("fine\nVERDICT: CLEAN\n")
        defer { try? FileManager.default.removeItem(at: url) }
        var d = CodexDecoder(answerFile: url)
        _ = d.consume(line: "progress")
        let r = d.finish(exit: exit())
        #expect(r.outcome == .succeeded && r.answer == .file(url) && r.failure == nil)
        var crashed = CodexDecoder(answerFile: url)
        #expect(crashed.finish(exit: exit(.exited(70))).outcome == .failed, "an answer from a crash is not a success")
    }

    @Test func noAnswerIsUnknownAndCapacityIsATransientFailure() throws {
        let missing = try answer(nil)
        var none = CodexDecoder(answerFile: missing)
        let r = none.finish(exit: exit())
        #expect(r.outcome == .unknown && r.answer == nil && r.failure == nil)

        var viaStream = CodexDecoder(answerFile: missing)
        _ = viaStream.consume(line: "ERROR: Selected model is at capacity right now")
        let a = viaStream.finish(exit: exit(.exited(1)))
        #expect(a.failure?.kind == .capacity && a.failure?.retry == .transient)

        var viaStderr = CodexDecoder(answerFile: missing)
        #expect(viaStderr.finish(exit: exit(.exited(1), tail: "Model AT CAPACITY")).failure?.kind == .capacity)

        let empty = try answer("  ")
        defer { try? FileManager.default.removeItem(at: empty) }
        var blank = CodexDecoder(answerFile: empty)
        _ = blank.consume(line: "at capacity")
        #expect(blank.finish(exit: exit(.exited(1))).failure?.kind == .capacity, "a blank file is no answer")
    }

    @Test func anAnswerBeatsAMentionOfCapacity() throws {
        let url = try answer("x\nVERDICT: FIX\n")
        defer { try? FileManager.default.removeItem(at: url) }
        var d = CodexDecoder(answerFile: url)
        _ = d.consume(line: "the code handles at capacity errors")
        #expect(d.finish(exit: exit()).failure == nil)
    }
}
