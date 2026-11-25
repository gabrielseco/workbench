import Foundation
import Testing

@testable import WorkbenchCore

private let oneCriterion = #"{"criteria": [{"id": "c1", "met": true, "evidence": ["a.txt now says hello."]}], "concerns": []}"#
private let gatewayKey = "judge-gateway-key-0123456789"

/// An `opencode` that answers a judge: the prompt it was given, its arguments, its working directory and the environment it holds are
/// kept per run, and its last message is the file `answer` (a verdict as text, since OpenCode has no structured output). It reaches no
/// gateway: the forwarder it is pointed at is started and stopped around the turn, and nothing here sends it a request.
private struct OpencodeJudged {
    var fx: RunnerFixture
    var id: String
    var config: Config
    var dir: URL

    func judge(again: Bool = false, environment: [String: String]? = nil) async throws -> JudgeResult {
        try await fx.service.judge(id: id, config: config, again: again, environment: environment ?? env())
    }

    func env(key: String? = gatewayKey) -> [String: String] {
        var e = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "USER": NSUserName()]
        e["GITHUB_TOKEN"] = "ghp_not_for_the_model"
        if let key { e["LITELLM_API_KEY"] = key }
        return e
    }

    var events: [Event] { (try? fx.events(id)) ?? [] }
    func read(_ name: String) -> String? { try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8) }
    var runs: Int { Int(read("n")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "0") ?? 0 }
    var judgeFolder: URL { fx.project.threadDirectory(id).appendingPathComponent("judge") }

    /// The port its forwarder had for the turn, from the config written for it.
    func forwarderPort() throws -> Int {
        let text = try String(contentsOf: judgeFolder.appendingPathComponent("opencode/opencode.json"), encoding: .utf8)
        let match = try #require(text.range(of: #"http://127\.0\.0\.1:[0-9]+"#, options: .regularExpression))
        return try #require(Int(text[match].split(separator: ":").last ?? ""))
    }
}

// swiftlint:disable line_length
private func opencodeJudged(answer: String? = oneCriterion, screenshots: Bool = false) async throws -> OpencodeJudged {
    let fx = try await RunnerFixture()
    let (id, _) = try await acceptedThread(fx)
    if screenshots { try await recordVerifierProof(fx, id, ["home.png": "pixels"]) }
    let dir = fx.repo.deletingLastPathComponent().appendingPathComponent("opencode-judge-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    if let answer { try answer.write(to: dir.appendingPathComponent("answer"), atomically: true, encoding: .utf8) }
    let script = dir.appendingPathComponent("opencode")
    try """
        #!/bin/sh
        D="\(dir.path)"
        n=$(cat "$D/n" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "$D/n"
        for a in "$@"; do p="$a"; done
        printf '%s' "$p" > "$D/prompt_$n"
        echo "$@" > "$D/args_$n"
        pwd -P > "$D/cwd_$n"
        printf 'key=%s gh=%s cfg=%s' "$LITELLM_API_KEY" "$GITHUB_TOKEN" "$OPENCODE_CONFIG" > "$D/env_$n"
        text=$(sed 's/\\\\/\\\\\\\\/g; s/"/\\\\"/g' "$D/answer" 2>/dev/null | tr -d '\\n')
        echo '{"type":"step_start","sessionID":"ses_1","part":{"type":"step-start"}}'
        echo '{"type":"text","sessionID":"ses_1","part":{"type":"text","text":"'"$text"'"}}'
        [ -f "$D/nostop" ] && exit 0
        echo '{"type":"step_finish","sessionID":"ses_1","part":{"type":"step-finish","reason":"stop","cost":0.07,"tokens":{"input":100,"output":30}}}'
        """.write(to: script, atomically: true, encoding: .utf8)
    chmod(script.path, 0o755)
    var config = try Config.load(from: fx.project.configURL)
    config.agents.judge = AgentSelection(provider: .opencode, model: "sonnet-claude", allowUnpriced: true)
    config.agents.opencode = OpencodeProvider.Gateway(baseURL: "http://127.0.0.1:9/v1")
    config.agents.executables[.opencode] = script.path
    return OpencodeJudged(fx: fx, id: id, config: config, dir: dir)
}
// swiftlint:enable line_length

@Suite(.processGate, .serialized) struct JudgeOpencodeTests {
    @Test func anOpencodeJudgeGivesAVerdictAndRecordsItsProviderModelAndCost() async throws {
        let j = try await opencodeJudged()
        let result = try await j.judge()
        #expect(result.failure == nil, "\(String(describing: result.failure))")
        #expect(result.verdict?.criteria.map(\.met) == [true])
        #expect(result.costUSD == 0.07, "the gateway's cost is carried, not unknown")
        let ran = try #require(j.events.last { $0.kind == .judgeRan })
        #expect(ran.data["ok"] == true && ran.data["provider"] == "opencode" && ran.data["model"] == "sonnet-claude")
        let kinds = j.events.suffix(4).map(\.kind)
        #expect(kinds == [.judgeStarted, .agentAttemptStarted, .agentAttemptEnded, .judgeRan], "\(kinds)")
        #expect(j.runs == 1)
    }

    @Test func theJudgeHoldsAPlaceholderNeverTheKeyAndReadsOnlyAnEmptyFolder() async throws {
        let j = try await opencodeJudged()
        _ = try await j.judge()
        let env = try #require(j.read("env_1"))
        #expect(env.contains("key=forwarder"), "a placeholder: \(env)")
        #expect(!env.contains(gatewayKey), "the real key never reaches it: \(env)")
        #expect(env.contains("gh=") && !env.contains("ghp_"), "nor does the parent's other credentials: \(env)")
        let cwd = try #require(j.read("cwd_1")).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(cwd.hasSuffix("/judge/empty"), "it reads an empty folder of its own, with the answer outside it: \(cwd)")
        let args = try #require(j.read("args_1"))
        #expect(args.contains("run --standalone --format json --archived -m gateway/sonnet-claude --"), "\(args)")
        #expect(!args.contains("--auto"))
        // Nothing the thread kept holds the key (the verdict goes into the log).
        let root = j.fx.project.threadDirectory(j.id)
        let names = (try? FileManager.default.subpathsOfDirectory(atPath: root.path)) ?? []
        for name in names {
            let url = root.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            guard exists, !isDirectory.boolValue else { continue }
            let data = (try? Data(contentsOf: url)) ?? Data()
            #expect(data.range(of: Data(gatewayKey.utf8)) == nil, "the key is in \(name)")
        }
    }

    @Test func theJudgesOwnConfigDeniesEditsAndTheShell() async throws {
        let j = try await opencodeJudged()
        _ = try await j.judge()
        let data = try Data(contentsOf: j.judgeFolder.appendingPathComponent("opencode/opencode.json"))
        let written = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rules = try #require(written["permission"] as? [String: Any])
        #expect(rules["edit"] as? String == "deny" && (rules["bash"] as? [String: String]) == ["*": "deny"])
        #expect(!FileManager.default.fileExists(atPath: j.judgeFolder.appendingPathComponent("opencode/sandbox.sb").path))
    }

    @Test func theForwarderIsStoppedWhenTheJudgeEnds() async throws {
        let j = try await opencodeJudged()
        _ = try await j.judge()
        let port = try j.forwarderPort()
        #expect(pollUntil(seconds: 10) { Client.dial(port) == nil }, "the forwarder still accepts connections")
    }

    @Test func aJudgeWithScreenshotsIsRefusedByNameBecauseOpencodeTakesNoImages() async throws {
        let j = try await opencodeJudged(screenshots: true)
        let result = try await j.judge()
        #expect(result.verdict == nil)
        let why = try #require(result.failure)
        #expect(why.contains("images") && why.contains("opencode"), "\(why)")
        #expect(j.runs == 0, "nothing was started, and no forwarder")
        #expect(j.events.last { $0.kind == .judgeRan }?.data["ok"] == false)
    }

    @Test func aMissingOrShortKeyIsAJudgeFailureNamingItAndNothingStarts() async throws {
        let j = try await opencodeJudged()
        let missing = try await j.judge(environment: j.env(key: nil))
        #expect(missing.failure?.contains("$LITELLM_API_KEY") == true, "\(String(describing: missing.failure))")
        let short = try await j.judge(again: true, environment: j.env(key: "short"))
        #expect(short.failure?.contains("shorter than 8") == true, "\(String(describing: short.failure))")
        #expect(j.runs == 0)
    }

    @Test func aValidVerdictFromATurnThatNeverFinishedIsNoVerdict() async throws {
        let j = try await opencodeJudged()
        try "".write(to: j.dir.appendingPathComponent("nostop"), atomically: true, encoding: .utf8)
        let result = try await j.judge()
        // The text is a well-formed verdict, but the stream stopped short of its final stop, and exit 0 with empty stderr said nothing else.
        #expect(result.verdict == nil, "an answer from a turn that did not finish is not used")
        #expect(result.failure?.contains("did not finish its turn") == true, "\(String(describing: result.failure))")
        let ran = try #require(j.events.last { $0.kind == .judgeRan })
        #expect(ran.data["ok"] == false, "the record says so, and not ok: true")
        let ended = try #require(j.events.last { $0.kind == .agentAttemptEnded })
        #expect(ended.data["outcome"] != "succeeded", "nor is the attempt recorded as a success: \(ended.data)")
        #expect(j.runs == 1)
    }

    @Test func anAnswerThatIsNotAVerdictIsAFailureNotAGuess() async throws {
        let j = try await opencodeJudged(answer: "Looks good to me.")
        let result = try await j.judge()
        #expect(result.verdict == nil && result.failure?.contains("verdict was not usable") == true)
    }

    @Test func aMissingOpencodeIsAJudgeFailureAndNothingStarts() async throws {
        var j = try await opencodeJudged()
        j.config.agents.executables[.opencode] = "/nonexistent/opencode"
        let result = try await j.judge()
        // Machine paths are scrubbed from what a judge records, so the path itself is not in it.
        let why = try #require(result.failure)
        #expect(why.contains("Could not find") && why.contains("Install OpenCode"), "\(why)")
        #expect(!why.contains("/nonexistent"))
        #expect(j.runs == 0)
    }
}
