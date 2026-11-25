import Foundation
import Testing

@testable import WorkbenchCore

private let gatewayKey = "review-gateway-key-0123456789"

/// An `opencode` that answers a review: its prompt, arguments, working directory and environment are kept per run, and its last message is
/// the text of `answer`. It reaches no gateway: the forwarder it is pointed at is started and stopped around the turn.
private struct OpencodeReviewed {
    var r: ReviewedPR
    var dir: URL

    func round(key: String? = gatewayKey) async throws -> PRReviewResult {
        var env = r.codex.environment()
        if let key { env["LITELLM_API_KEY"] = key }
        env["GITHUB_TOKEN"] = "ghp_not_for_the_model"
        return try await r.round(environment: env)
    }

    func read(_ name: String) -> String? { try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8) }
    var runs: Int { Int(read("n")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "0") ?? 0 }
}

// swiftlint:disable line_length
private func opencodeReviewed(
    answer: String = "Nothing found.\nVERDICT: CLEAN\n", extraConfig: String = "", stops: Bool = true
) async throws -> OpencodeReviewed {
    var r = try await reviewedPR(extraConfig: extraConfig)
    let dir = r.fx.repo.deletingLastPathComponent().appendingPathComponent("opencode-review-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let line: [String: Any] = ["type": "text", "sessionID": "ses_1", "part": ["type": "text", "text": answer]]
    let json = try JSONSerialization.data(withJSONObject: line)
    try json.write(to: dir.appendingPathComponent("text.json"))
    let script = dir.appendingPathComponent("opencode")
    try """
        #!/bin/sh
        D="\(dir.path)"
        n=$(cat "$D/n" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "$D/n"
        for a in "$@"; do p="$a"; done
        printf '%s' "$p" > "$D/prompt_$n"
        echo "$@" > "$D/args_$n"
        pwd -P > "$D/cwd_$n"
        printf 'key=%s gh=%s' "$LITELLM_API_KEY" "$GITHUB_TOKEN" > "$D/env_$n"
        echo '{"type":"step_start","sessionID":"ses_1","part":{"type":"step-start"}}'
        cat "$D/text.json"; echo
        [ -f "$D/nostop" ] && exit 0
        echo '{"type":"step_finish","sessionID":"ses_1","part":{"type":"step-finish","reason":"stop","cost":0.07,"tokens":{"input":1,"output":1}}}'
        """.write(to: script, atomically: true, encoding: .utf8)
    chmod(script.path, 0o755)
    if !stops { try "".write(to: dir.appendingPathComponent("nostop"), atomically: true, encoding: .utf8) }
    r.config.agents.review = AgentSelection(provider: .opencode, model: "sonnet-claude", allowUnpriced: true)
    r.config.agents.opencode = OpencodeProvider.Gateway(baseURL: "http://127.0.0.1:9/v1")
    r.config.agents.executables[.opencode] = script.path
    return OpencodeReviewed(r: r, dir: dir)
}
// swiftlint:enable line_length

@Suite(.processGate, .serialized) struct PRReviewOpencodeTests {
    @Test func anOpencodeReviewGivesAVerdictAndRecordsItsCost() async throws {
        let o = try await opencodeReviewed()
        let result = try await o.round()
        #expect(result.failure == nil, "\(String(describing: result.failure))")
        #expect(result.verdict == .clean)
        #expect(result.costUSD == 0.07, "the gateway's cost is carried, not unknown: \(String(describing: result.costUSD))")
        #expect(o.r.finished.first?.data["ok"] == true && o.r.finished.first?.data["provider"] == "opencode")
        #expect(o.runs == 1)
        try await o.r.expectNoLeftovers()
    }

    @Test func aFindingEndsInFixAndIsKept() async throws {
        let o = try await opencodeReviewed(answer: "a.txt line 3 drops the check.\nVERDICT: FIX\n")
        let result = try await o.round()
        #expect(result.verdict == .fix)
        #expect(result.findings?.contains("drops the check") == true)
    }

    @Test func theReviewerHoldsAPlaceholderNeverTheKeyAndReadsTheRoundsFolder() async throws {
        let o = try await opencodeReviewed()
        _ = try await o.round()
        let env = try #require(o.read("env_1"))
        #expect(env.contains("key=forwarder") && !env.contains(gatewayKey), "the real key never reaches it: \(env)")
        #expect(!env.contains("ghp_"), "nor does the parent's other credentials: \(env)")
        let cwd = try #require(o.read("cwd_1")).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(cwd.hasSuffix("/pr-review"), "it reads the round's folder (brief, diff, checkout), not the project: \(cwd)")
        let args = try #require(o.read("args_1"))
        #expect(args.contains("run --standalone --format json --archived -m gateway/sonnet-claude --"), "\(args)")
        #expect(!args.contains("--auto"))
        let prompt = try #require(o.read("prompt_1"))
        #expect(prompt.contains("round-1.brief.md") && prompt.contains("round-1.tree"), "\(prompt)")
        // The base URL it was given is the loopback forwarder, never the gateway.
        let config = try String(contentsOf: o.r.folder.appendingPathComponent("opencode/opencode.json"), encoding: .utf8)
        #expect(config.contains("http://127.0.0.1:") && !config.contains(":9/v1") && !config.contains(gatewayKey))
        // Nothing the thread kept holds the key.
        let root = o.r.fx.project.threadDirectory(o.r.id)
        for name in (try? FileManager.default.subpathsOfDirectory(atPath: root.path)) ?? [] {
            let data = (try? Data(contentsOf: root.appendingPathComponent(name))) ?? Data()
            #expect(data.range(of: Data(gatewayKey.utf8)) == nil, "the key is in \(name)")
        }
    }

    @Test func aStreamThatNeverFinishedIsNoReviewEvenWithAVerdictLine() async throws {
        let o = try await opencodeReviewed(stops: false)
        let result = try await o.round()
        #expect(result.verdict == nil, "a clean verdict from a turn that did not end is not one")
        #expect(result.failure?.contains("did not finish its turn") == true, "\(String(describing: result.failure))")
        #expect(o.r.finished.first?.data["ok"] == false)
    }

    @Test func aMissingKeyIsRefusedBeforeAnythingStarts() async throws {
        let o = try await opencodeReviewed()
        let result = try await o.round(key: nil)
        #expect(result.verdict == nil)
        #expect(result.failure?.contains("LITELLM_API_KEY") == true, "\(String(describing: result.failure))")
        #expect(o.runs == 0, "no process was started")
    }

    @Test func aStageThatReadsScreenshotsIsRefusedOnOpencode() async throws {
        let o = try await opencodeReviewed(extraConfig: "[review.stage.pr-review]\ninputs = [\"diff\", \"proof\"]")
        let result = try await o.round()
        #expect(result.verdict == nil && result.failure?.contains("opencode cannot take images") == true)
        #expect(o.runs == 0)
    }

    @Test func theForwarderIsGoneWhenTheRoundIsOver() async throws {
        let o = try await opencodeReviewed()
        _ = try await o.round()
        let config = try String(contentsOf: o.r.folder.appendingPathComponent("opencode/opencode.json"), encoding: .utf8)
        let match = try #require(config.range(of: #"http://127\.0\.0\.1:[0-9]+"#, options: .regularExpression))
        let port = try #require(Int(config[match].split(separator: ":").last ?? ""))
        #expect(pollUntil(seconds: 10) { Client.dial(port) == nil }, "the listener is closed")
    }
}
