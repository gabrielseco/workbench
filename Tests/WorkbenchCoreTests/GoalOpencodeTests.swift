import Foundation
import Testing

@testable import WorkbenchCore

private let gatewayKey = "goal-gateway-key-0123456789"

/// A drafting fixture whose goal agent is a fake `opencode`: its last message is `answer`, its prompt, arguments, working directory and
/// environment are kept per run. It reaches no gateway; the forwarder it is pointed at is started and stopped around the turn.
private struct OpencodeDrafting {
    var d: Drafting
    var script: URL

    var environment: [String: String] {
        [
            "PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "LITELLM_API_KEY": gatewayKey,
            "GITHUB_TOKEN": "ghp_not_for_the_model",
        ]
    }

    func read(_ name: String) -> String? { try? String(contentsOf: d.dir.appendingPathComponent(name), encoding: .utf8) }
    var runs: Int { Int(read("n")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "0") ?? 0 }
}

// swiftlint:disable line_length
private func opencodeDrafting(answer: String = proposalJSON, stops: Bool = true) async throws -> OpencodeDrafting {
    var d = try await drafting(provider: .opencode, allowUnpriced: true, answer: nil, model: "opus-claude")
    let line: [String: Any] = ["type": "text", "sessionID": "ses_1", "part": ["type": "text", "text": answer]]
    try JSONSerialization.data(withJSONObject: line).write(to: d.dir.appendingPathComponent("text.json"))
    let script = d.dir.appendingPathComponent("opencode")
    try """
        #!/bin/sh
        D="\(d.dir.path)"
        n=$(cat "$D/n" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "$D/n"
        for a in "$@"; do p="$a"; done
        printf '%s' "$p" > "$D/prompt_$n"
        echo "$@" > "$D/args_$n"
        pwd -P > "$D/cwd_$n"
        printf 'key=%s gh=%s' "$LITELLM_API_KEY" "$GITHUB_TOKEN" > "$D/env_$n"
        echo '{"type":"step_start","sessionID":"ses_1","part":{"type":"step-start"}}'
        cat "$D/text.json"; echo
        [ -f "$D/nostop" ] && exit 0
        echo '{"type":"step_finish","sessionID":"ses_1","part":{"type":"step-finish","reason":"stop","cost":0.05,"tokens":{"input":1,"output":1}}}'
        """.write(to: script, atomically: true, encoding: .utf8)
    chmod(script.path, 0o755)
    if !stops { try "".write(to: d.dir.appendingPathComponent("nostop"), atomically: true, encoding: .utf8) }
    d.config.agents.opencode = OpencodeProvider.Gateway(baseURL: "http://127.0.0.1:9/v1")
    d.config.agents.executables[.opencode] = script.path
    return OpencodeDrafting(d: d, script: script)
}
// swiftlint:enable line_length

@Suite(.processGate, .serialized) struct GoalOpencodeTests {
    @Test func anOpencodeDrafterProposesAGoalAndRecordsItsCost() async throws {
        let o = try await opencodeDrafting()
        let result = try await o.d.draft(environment: o.environment)
        #expect(result.failure == nil, "\(String(describing: result.failure))")
        #expect(result.proposal?.title == "Add retry")
        #expect(result.provider == .opencode && result.costUSD == 0.05, "\(String(describing: result.costUSD))")
        #expect(o.runs == 1)
    }

    @Test func theDrafterHoldsAPlaceholderAndReadsOnlyItsEmptyFolder() async throws {
        let o = try await opencodeDrafting()
        _ = try await o.d.draft(environment: o.environment)
        let env = try #require(o.read("env_1"))
        #expect(env.contains("key=forwarder") && !env.contains(gatewayKey), "\(env)")
        #expect(!env.contains("ghp_"), "\(env)")
        let cwd = try #require(o.read("cwd_1")).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(cwd.hasSuffix("/work"), "an empty folder of its own: \(cwd)")
        let args = try #require(o.read("args_1"))
        #expect(args.contains("-m gateway/opus-claude --") && !args.contains("--auto"), "\(args)")
    }

    @Test func aStreamThatNeverFinishedIsNoProposalEvenWithValidJSON() async throws {
        let o = try await opencodeDrafting(stops: false)
        let result = try await o.d.draft(environment: o.environment)
        #expect(result.proposal == nil)
        #expect(result.failure?.contains("did not finish its turn") == true, "\(String(describing: result.failure))")
        #expect(o.d.threads.isEmpty, "no thread is made from it")
    }

    @Test func aMissingKeyIsRefusedBeforeAnyProcessStarts() async throws {
        let o = try await opencodeDrafting()
        var env = o.environment
        env["LITELLM_API_KEY"] = nil
        do {
            let result = try await o.d.draft(environment: env)
            #expect(result.proposal == nil)
            #expect(result.failure?.contains("LITELLM_API_KEY") == true, "\(String(describing: result.failure))")
        } catch let refusal as GoalDraftRefusal {
            #expect("\(refusal)".contains("LITELLM_API_KEY"), "\(refusal)")
        }
        #expect(o.runs == 0)
    }

    @Test func screenshotsAreRefusedForOpencodeByName() async throws {
        let o = try await opencodeDrafting()
        let image = try o.d.image("shot.png")
        do {
            _ = try await o.d.draft(attachments: [image], environment: o.environment)
            Issue.record("a draft with screenshots started on opencode")
        } catch let refusal as GoalDraftRefusal {
            #expect("\(refusal)".contains("opencode cannot take images"), "\(refusal)")
        }
        #expect(o.runs == 0 && o.d.threads.isEmpty)
    }

    @Test func aChatScreenshotIsRefusedBeforeTheActiveThreadIsAbandoned() async throws {
        let o = try await opencodeDrafting()
        let image = try o.d.image("shot.png")
        // An active thread that a new chat would have to abandon (the fixture allows one).
        let drafted = try await o.d.draft(environment: o.environment)
        let active = try #require(drafted.id)
        do {
            _ = try await o.d.fx.service.chat(
                target: .newThread(name: "idea"), message: "look at this", config: o.d.config, attachments: [image],
                abandonActive: true, environment: o.environment)
            Issue.record("a chat with a screenshot started on opencode")
        } catch let refusal as ChatRefusal {
            #expect("\(refusal)".contains("opencode cannot take images"), "\(refusal)")
        }
        let state = ThreadStore(project: o.d.fx.project).state(of: active)
        #expect(state.decision == nil, "the active thread was not abandoned")
        #expect(o.d.threads == [active], "and no chat thread was made: \(o.d.threads)")
    }

    @Test func aChatTurnAndATaskEditRunOnOpencodeBehindTheForwarder() async throws {
        let o = try await opencodeDrafting(answer: "What should happen after the fifth try?")
        let chat = try await o.d.fx.service.chat(
            target: .newThread(name: "idea"), message: "what about retries?", config: o.d.config, environment: o.environment)
        #expect(chat.failure == nil, "\(String(describing: chat.failure))")
        #expect(chat.reply == "What should happen after the fifth try?")
        let env = try #require(o.read("env_1"))
        #expect(env.contains("key=forwarder") && !env.contains(gatewayKey), "\(env)")

        let task = try TaskFixture(in: o.d.fx.project)
        let edit = try await TaskEditor(project: task.project).propose(
            task: task.name, request: "allow three dollars", config: o.d.config, environment: o.environment, timeout: 30)
        #expect(o.runs == 2, "both turns ran")
        let env2 = try #require(o.read("env_2"))
        #expect(env2.contains("key=forwarder") && !env2.contains(gatewayKey), "\(env2)")
        _ = edit
    }
}
