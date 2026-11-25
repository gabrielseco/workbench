import Foundation
import Testing

@testable import WorkbenchCore

/// A fake `opencode` on a PATH of its own: a shell script that answers by the word in the prompt, in the event format the real one
/// printed (docs/plan/P28-probes/fixtures), so the agent is tested with real processes and no model.
private struct Fixture {
    let root: URL
    let bin: URL
    let scratch: TurnScratch
    let checkout: URL

    init() throws {
        let base = try #require(realpath(NSTemporaryDirectory(), nil).map { String(cString: $0) })
        root = URL(fileURLWithPath: base).appendingPathComponent("oc-agent-\(UUID().uuidString)")
        bin = root.appendingPathComponent("bin")
        checkout = root.appendingPathComponent("checkout")
        scratch = TurnScratch(url: root.appendingPathComponent("scratch"))
        for dir in [bin, checkout] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        // swiftlint:disable line_length
        let script = """
            #!/bin/sh
            for last; do :; done
            ev() { printf '%s\\n' "$1"; }
            case "$last" in
            *MODE-OK*)
              ev '{"type":"step_start","sessionID":"ses_1","part":{"type":"step-start"}}'
              ev "{\\"type\\":\\"text\\",\\"sessionID\\":\\"ses_1\\",\\"part\\":{\\"type\\":\\"text\\",\\"text\\":\\"cwd=$(pwd) key=$LITELLM_API_KEY gh=$GITHUB_TOKEN cfg=$OPENCODE_CONFIG\\"}}"
              ev '{"type":"step_finish","sessionID":"ses_1","part":{"type":"step-finish","reason":"stop","cost":0.25,"tokens":{"input":100,"output":20,"reasoning":0,"cache":{"read":0,"write":0}}}}' ;;
            *MODE-GATEWAY*)
              ev '{"type":"step_start","sessionID":"ses_1","part":{"type":"step-start"}}'
              ev '{"type":"error","sessionID":"ses_1","error":{"type":"provider.internal","message":"Service Unavailable","status":503}}'
              exit 1 ;;
            *MODE-NOSTOP*)
              ev '{"type":"text","sessionID":"ses_1","part":{"type":"text","text":"half an answer"}}' ;;
            *MODE-HANG*)
              exec sleep 30 ;;
            esac
            """
        // swiftlint:enable line_length
        let exe = bin.appendingPathComponent("opencode")
        try script.write(to: exe, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    var environment: [String: String] {
        ["PATH": "\(bin.path):/usr/bin:/bin", "HOME": "/h", "LITELLM_API_KEY": "the-key", "GITHUB_TOKEN": "gh-secret"]
    }

    func agent(_ env: [String: String]? = nil) -> OpencodeReadOnlyAgent {
        OpencodeReadOnlyAgent(
            gateway: OpencodeProvider.Gateway(baseURL: "https://gw.example/v1"), environment: env ?? environment)
    }

    func request(_ mode: String, tools: ReadOnlyTools = .none, timeout: TimeInterval = 20) -> ReadOnlyRequest {
        ReadOnlyRequest(
            prompt: "Please answer. \(mode)", workingDirectory: checkout, model: "sonnet-claude", budget: 1, timeout: timeout,
            tools: tools, scratch: scratch)
    }
}

@Suite struct OpencodeReadOnlyAgentTests {
    @Test func aTurnWithNoToolsRunsInAnEmptyFolderAndAnswersWithItsLastText() async throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        let answer = await f.agent().run(f.request("MODE-OK")) { _ in }
        #expect(answer.failure == nil)
        let text = try #require(answer.text)
        #expect(text.contains("cwd=\(f.scratch.url.path)/empty"), "it cannot read the checkout: \(text)")
        #expect(text.contains("key=the-key") && text.contains("gh="), "the key reaches it and nothing else does: \(text)")
        #expect(!text.contains("gh-secret"))
        #expect(text.contains("cfg=\(f.scratch.url.path)/opencode/opencode.json"), "it runs on the config Workbench wrote")
        #expect(answer.costUSD == 0.25, "the gateway's per-step cost is carried, not unknown")
        #expect(!FileManager.default.fileExists(atPath: f.scratch.url.path), "whatever it wrote goes with the turn")
    }

    @Test func aPlanTurnReadsTheCheckoutItIsGiven() async throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        let answer = await f.agent().run(f.request("MODE-OK", tools: .read)) { _ in }
        let text = try #require(answer.text)
        #expect(text.contains("cwd=\(f.checkout.path)"), "\(text)")
    }

    @Test func aGatewayErrorIsTheTurnsFailureInTheAdaptersWords() async throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        let answer = await f.agent().run(f.request("MODE-GATEWAY")) { _ in }
        #expect(answer.text == nil)
        let why = try #require(answer.failure)
        #expect(why.contains("busy or unreachable") && why.contains("Service Unavailable"), "\(why)")
    }

    @Test func aStreamThatNeverEndedItsTurnIsNotAnAnswer() async throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        let answer = await f.agent().run(f.request("MODE-NOSTOP")) { _ in }
        #expect(answer.text == nil, "half an answer is not one")
        #expect(answer.failure == "opencode left no answer")
    }

    @Test func aTurnPastItsDeadlineIsEndedAndSaysSoAndLeavesNothingBehind() async throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        let answer = await f.agent().run(f.request("MODE-HANG", timeout: 1)) { _ in }
        #expect(answer.failure?.contains("did not answer within 1s") == true, "\(String(describing: answer.failure))")
        #expect(!FileManager.default.fileExists(atPath: f.scratch.url.path))
    }

    @Test func theLoggedCommandNamesTheModelWithoutThePromptAndWritesNothing() throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        let shown = f.agent().shownArguments(for: f.request("MODE-OK"))
        #expect(shown.contains("gateway/sonnet-claude") && shown.contains("--standalone") && !shown.contains("--auto"))
        #expect(!shown.joined(separator: " ").contains("MODE-OK"), "the prompt is not in the log")
        #expect(!FileManager.default.fileExists(atPath: f.scratch.url.path), "asking for the command makes no folder")
    }

    @Test func aMissingExecutableOrKeyIsRefusedBeforeAnythingRuns() async throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        var noPath = f.environment
        noPath["PATH"] = "/nonexistent"
        #expect(f.agent(noPath).unavailable()?.contains("was not found") == true)
        #expect(f.agent().unavailable() == nil)
        var noKey = f.environment
        noKey["LITELLM_API_KEY"] = nil
        let answer = await f.agent(noKey).run(f.request("MODE-OK")) { _ in }
        #expect(answer.text == nil)
        #expect(answer.failure?.contains("LITELLM_API_KEY is not set") == true, "\(String(describing: answer.failure))")
    }

    @Test func aRequestWithNoFolderToKeepItsRunInIsRefused() async throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        var request = f.request("MODE-OK")
        request.scratch = nil
        let answer = await f.agent().run(request) { _ in }
        #expect(answer.failure == "opencode has no folder to keep its run in")
    }
}
