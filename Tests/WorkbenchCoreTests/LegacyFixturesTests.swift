import Foundation
import Testing

@testable import WorkbenchCore

/// `Tests/Fixtures/legacy/<name>/`: a config and the log and `session.json` a thread had before P9 (claude lines only, no
/// attempt records, no provider in `turn.started`, an approval without provider or model). The configs have no `[agents]`
/// table, except `models`, whose root `model` and `judge_model` were rewritten to `[agents.run]` and `[agents.judge]` when
/// those keys were removed. `status.expected.json`, `review.expected.json` and `doctor.expected.txt` were produced by the
/// `workbench` built from `origin/main` before this change (011ce70), and are not regenerated from this code.
private let fixtures = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/legacy")

private let threadID = "g-2026-10-13-legacy"

private struct Scenario {
    var name: String
    var model: String?
    var judgeModel: String?
    var lastTurn: Int
    var cost: Double
    var decision: String?
    var judged: Bool
    var prVerdict: String?
    var denials: Int
}

private let scenarios = [
    Scenario(
        name: "bare", model: nil, judgeModel: nil, lastTurn: 1, cost: 0.12, decision: nil, judged: false,
        prVerdict: nil, denials: 0),
    // Its result line lists one refused call; `claude` events are no longer read, so an unmigrated log shows none.
    Scenario(
        name: "models", model: "opus", judgeModel: "haiku", lastTurn: 1, cost: 0.12, decision: nil, judged: true,
        prVerdict: nil, denials: 0),
    Scenario(
        name: "codex-review", model: nil, judgeModel: nil, lastTurn: 1, cost: 0.12, decision: nil, judged: true,
        prVerdict: "clean", denials: 0),
    Scenario(
        name: "sent-back-accepted", model: nil, judgeModel: nil, lastTurn: 2, cost: 0.32, decision: "accepted",
        judged: false,
        prVerdict: nil, denials: 0),
]

private func text(_ name: String, _ file: String) throws -> String {
    try String(contentsOf: fixtures.appendingPathComponent(name).appendingPathComponent(file), encoding: .utf8)
}

private struct LegacyProject {
    var root: URL
    var home: URL
}

/// The fixture as a project: a git repo on `main`, its config, and the thread's log and session.
private func project(_ name: String) async throws -> LegacyProject {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("wb-legacy-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let root = base.resolvingSymlinksInPath()
    let home = root.appendingPathComponent("home")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let repo = root.appendingPathComponent("repo")
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    let git = try isolatedGit()
    _ = try await git.run(["init", "-q", "-b", "main"], in: repo)
    try "one\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    _ = try await git.run(["add", "-A"], in: repo)
    _ = try await git.run(["commit", "-q", "-m", "first"], in: repo)
    let project = Project(root: repo)
    try FileManager.default.createDirectory(at: project.threadDirectory(threadID), withIntermediateDirectories: true)
    try text(name, "config.toml").write(to: project.configURL, atomically: true, encoding: .utf8)
    try text(name, "events.jsonl").write(to: project.eventsURL(threadID), atomically: true, encoding: .utf8)
    try text(name, "session.json").write(to: project.sessionURL(threadID), atomically: true, encoding: .utf8)
    return LegacyProject(root: repo, home: home)
}

private func run(_ arguments: [String], in fixture: LegacyProject) async throws -> String {
    let ran = try await workbenchCLI(
        arguments, in: fixture.root,
        environment: ["PATH": "/usr/bin:/bin", "HOME": fixture.home.path, "USER": "legacy"])
    #expect(ran.code == 0, "\(arguments): \(ran.stdout) \(ran.stderr)")
    var out = ran.stdout
    for path in [fixture.root.path, fixture.root.deletingLastPathComponent().path] {
        out = out.replacingOccurrences(of: path, with: "<root>")
    }
    return out.replacingOccurrences(of: fixture.home.path, with: "<home>")
}

@Suite(.processGate) struct LegacyFixturesTests {
    @Test func configsResolveAsBefore() throws {
        for scenario in scenarios {
            let config = try Config.load(
                from: fixtures.appendingPathComponent(scenario.name).appendingPathComponent("config.toml"))
            var tables = AgentsConfig()
            tables.run.model = scenario.model
            tables.judge.model = scenario.judgeModel
            #expect(config.agents == tables, "\(scenario.name): only the models the config names")
            #expect(
                config.resolvedRunAgent()
                    == ResolvedAgent(provider: .claude, model: scenario.model, allowUnpriced: false), "\(scenario.name)"
            )
            #expect(
                config.resolvedJudgeAgent()
                    == ResolvedAgent(provider: .claude, model: scenario.judgeModel, allowUnpriced: false),
                "\(scenario.name)")
            #expect(
                config.resolvedReviewAgent() == ResolvedAgent(provider: .codex, model: nil, allowUnpriced: false),
                "\(scenario.name)")
            #expect(config.resolvedGoalAgent == nil, "\(scenario.name): drafting stays manual")
            #expect(config.executable(for: .claude) == config.claudePath && config.executable(for: .codex) == "codex")
        }
    }

    @Test func logsReplayToSnapshot() throws {
        for scenario in scenarios {
            let events = try EventLogReader.read(
                at: fixtures.appendingPathComponent(scenario.name).appendingPathComponent("events.jsonl")
            ).events
            let state = ThreadState.derive(from: events, id: threadID)
            #expect(state.lastTurn == scenario.lastTurn && state.openTurn == nil, "\(scenario.name)")
            #expect(abs(state.totalCostUSD - scenario.cost) < 1e-9, "\(scenario.name): \(state.totalCostUSD)")
            #expect(state.decision == scenario.decision && state.lastResult == "succeeded", "\(scenario.name)")
            #expect(
                state.approvedAgent == nil && state.approvedGoalHash == String(repeating: "a", count: 64),
                "binds nothing")
            #expect(state.sessionProvider == nil && state.sessionID == "11111111-2222-3333-4444-555555555555")
            #expect((state.review.judge?.verdict != nil) == scenario.judged, "\(scenario.name)")
            #expect(state.review.prReview?.verdict == scenario.prVerdict, "\(scenario.name)")
            #expect(state.review.deniedTools.count == scenario.denials, "\(scenario.name)")
            // Whatever it recorded, the new reading is the old default and says it was not recorded.
            #expect(
                state.agentUse.values.allSatisfy { !$0.recorded && $0.model == nil && $0.attempt == nil },
                "\(scenario.name)")
            #expect(state.agentUse["run"]?.provider == "claude", "\(scenario.name)")
            #expect(state.agentUse["review"] == nil || state.agentUse["review"]?.provider == "codex")
            let sessionData = try Data(
                contentsOf: fixtures.appendingPathComponent(scenario.name).appendingPathComponent("session.json"))
            let session = try JSONDecoder().decode(ThreadStore.Session.self, from: sessionData)
            #expect(session.provider == nil && session.confirmed, "\(scenario.name): session.json without a provider")
        }
    }

    @Test func cliJSONUnchangedBesidesNewKeys() async throws {
        for scenario in scenarios {
            let fixture = try await project(scenario.name)
            for command in ["status", "review"] {
                let now = try await run([command, "--json"], in: fixture)
                var current = try #require(JSONSerialization.jsonObject(with: Data(now.utf8)) as? [String: Any])
                // The two keys this change adds; the readers of a v1 object ignore keys they do not know.
                #expect(current["agents"] != nil && current["approved_for"] != nil, "\(scenario.name) \(command)")
                let approved = try #require(current["approved_for"] as? [String: Any])
                #expect(approved["provider"] as? String == "claude" && approved["recorded"] as? Bool == false)
                current["agents"] = nil
                current["approved_for"] = nil
                // PR 12 adds `spend_policy` (a goal with a cap reads `hard_cap`); status has it inside `goal`.
                #expect(approved["spend_policy"] as? String == "hard_cap")
                current["spend_policy"] = nil
                if var goal = current["goal"] as? [String: Any] {
                    #expect(goal.removeValue(forKey: "spend_policy") as? String == "hard_cap")
                    current["goal"] = goal
                }
                var was = try #require(
                    JSONSerialization.jsonObject(with: Data(try text(scenario.name, "\(command).expected.json").utf8))
                        as? [String: Any])
                // The legacy verify step's `verify` key was removed (only the verifier reports proof now).
                #expect(current["verify"] == nil, "\(scenario.name) \(command)")
                #expect(was.removeValue(forKey: "verify") != nil, "\(scenario.name) \(command)")
                #expect(
                    NSDictionary(dictionary: current) == NSDictionary(dictionary: was), "\(scenario.name) \(command)")
            }
            let status = try #require(
                JSONSerialization.jsonObject(with: Data(try await run(["status", "--json"], in: fixture).utf8))
                    as? [String: Any])
            let run = try #require((status["agents"] as? [String: Any])?["run"] as? [String: Any])
            #expect(
                run["provider"] as? String == "claude" && run["model"] is NSNull && run["recorded"] as? Bool == false)
        }
    }

    @Test func doctorResultUnchanged() async throws {
        for scenario in scenarios {
            let fixture = try await project(scenario.name)
            let now = try await run(["doctor"], in: fixture)
            // What later changes add to the text: problems and notes per agent, the approved line, the ship and plan
            // agents.
            let kept = now.split(separator: "\n", omittingEmptySubsequences: false).filter {
                !$0.hasPrefix("  problem:") && !$0.hasPrefix("  note:") && !$0.hasPrefix("approved:")
                    && !$0.hasPrefix("agent ship:") && !$0.hasPrefix("agent plan:")
            }
            // With the root `model` removed, the hint names [agents.run], and the verifier no longer inherits the
            // coding model.
            let was = try text(scenario.name, "doctor.expected.txt")
                .replacingOccurrences(
                    of: "the claude CLI default (no `model` in the config)",
                    with: "the provider's default (no `model` in [agents.run])")
                .replacingOccurrences(of: "\n  model:  opus\n", with: "\n  model:  the claude CLI default\n")
            #expect(kept.joined(separator: "\n") == was.trimmingCharacters(in: .newlines), "\(scenario.name):\n\(now)")
        }
    }

    @Test func versionStaysOne() throws {
        #expect(Event.currentVersion == 1)
        for scenario in scenarios {
            let read = try EventLogReader.read(
                at: fixtures.appendingPathComponent(scenario.name).appendingPathComponent("events.jsonl"))
            #expect(read.problems.isEmpty, "\(scenario.name): \(read.problems)")
            #expect(read.events.allSatisfy { $0.v == 1 })
            #expect(
                !read.events.contains { [.agentAttemptStarted, .agentAttemptEnded, .agentActivity].contains($0.kind) })
        }
    }
}
