import Foundation
import Testing

@testable import WorkbenchCore

extension GoalDraftTests {
    @Test func fromClaudeSession() async throws {
        let d = try await drafting()
        let said: [ClaudeSession.Message] = [
            .init(.person, "## Make retries back off"), .init(.assistant, "Upload.swift retries."),
        ]
        let session = ClaudeSession.Rendered(
            id: "abc-1", file: URL(fileURLWithPath: "/nowhere.jsonl"), text: try ClaudeSession.bounded(said).text, dropped: 0)
        let target = GoalDraftTarget.fromClaudeSession(name: "retry", base: "main", session: session)
        // No goal agent: refused as --from-chat is, nothing spent or made.
        var off = d.config
        off.agents.goal = nil
        await #expect(throws: GoalDraftRefusal.noGoalAgent) {
            _ = try await d.fx.service.draftGoal(target: target, request: "", config: off, environment: d.environment)
        }
        #expect(d.codex?.runs == 0 && d.threads.isEmpty)
        // A failed draft leaves nothing behind.
        try d.codex?.put("answer", "not a goal")
        let failed = try await d.draft(target, request: "")
        #expect(failed.id == nil && failed.failure != nil && d.threads.isEmpty, "\(d.threads)")
        // A good one is a new draft thread on the base it was given, from the session, fenced as a conversation.
        try d.codex?.put("answer", proposalJSON)
        let result = try await d.draft(target, request: "")
        let id = try #require(result.id, "\(String(describing: result.failure))")
        let goal = try GoalFile.parse(String(contentsOf: d.fx.project.goalURL(id), encoding: .utf8))
        #expect(goal.goal.approval == .draft && goal.goal.base == "main")
        let prompt = (d.codex?.read("calls") ?? "").components(separatedBy: " -- ").last ?? ""
        #expect(prompt.contains("> ## Make retries back off"), "quoted, not structure")
        #expect(!prompt.contains("\n## Make retries back off"))
        #expect(prompt.contains("> Upload.swift retries."))
        let started = try #require(try d.fx.events(id).first { $0.kind == .goalDraftStarted })
        #expect(started.data["from_claude_session"] == "abc-1", "the log says where the draft came from")

        // The command: combined with --base, refused with the flags that say where else the request comes from.
        let home = d.dir.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let env = ["PATH": "/usr/bin:/bin", "HOME": home.path, "USER": NSUserName()]
        for extra in [["--request", "x"], ["--request-file", "/dev/null"], ["--from-chat"], ["--replace"]] {
            let ran = try await workbenchCLI(
                ["goal", "draft", "other", "--from-claude-session"] + extra, in: d.fx.repo, environment: env)
            #expect(ran.code == 2, "\(extra): \(String(describing: ran.code)) \(ran.stderr)")
        }
        // The project's config has no [agents.goal]: refused before the session is read.
        let noAgent = try await workbenchCLI(
            ["goal", "draft", "other", "--from-claude-session", "abc-1", "--base", "main"], in: d.fx.repo, environment: env)
        #expect(noAgent.code == 6 && noAgent.stderr.contains("goal drafting is off"), "\(noAgent.stderr)")
        #expect(d.threads == [id], "the refusals made nothing")

        // With a goal agent: no session for the project, or an unknown or unsafe id, is refused (6) naming where it looked.
        let fx = try await RunnerFixture(extraConfig: "[agents.goal]\nprovider = \"codex\"\nallow_unpriced = true")
        let looked = home.appendingPathComponent(".claude").path
        for extra in [[], ["99999999-0000-0000-0000-000000000000"], ["../x"]] {
            let ran = try await workbenchCLI(
                ["goal", "draft", "other", "--from-claude-session"] + extra, in: fx.repo, environment: env)
            #expect(ran.code == 6, "\(extra): \(String(describing: ran.code)) \(ran.stderr)")
            if extra.first != "../x" { #expect(ran.stderr.contains(looked), "\(ran.stderr)") }
        }
        let none = (try? FileManager.default.contentsOfDirectory(atPath: fx.project.threadsDirectory.path)) ?? []
        #expect(none.isEmpty, "nothing was made: \(none)")
    }
}
