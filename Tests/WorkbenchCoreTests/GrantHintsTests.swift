import Foundation
import Testing

@testable import WorkbenchCore

@Suite struct GrantPromptTests {
    @Test func theRulesSayOnlyTheUserCanAllowADeniedCommandAndNoWorkaround() {
        let rules = PromptBuilder.rules(checkCommand: nil)
        #expect(rules.contains("do not retry it and do not do the same thing another way"))
        #expect(rules.contains("say exactly which command you needed and why"))
        #expect(rules.contains("Only the user can allow it"))
        #expect(rules.contains("file tools, never with shell redirects or heredocs"))
    }

    @Test func aFollowUpListsWhatTheUserHasNowAllowedAsData() {
        let prompt = PromptBuilder.followUpPrompt(
            feedback: "Go on.", granted: ["Bash(chmod +x scripts/a.sh)", "Bash(echo `x`)"])
        let section = prompt.range(of: "The user has now allowed these commands")
        #expect(section != nil)
        #expect(prompt.contains("Bash(chmod +x scripts/a.sh)\nBash(echo `x`)"))
        #expect(prompt.contains("```\nBash(chmod"), "a fence longer than the longest run of backticks inside")
        #expect(prompt.hasPrefix("The reviewer sent this back with feedback:\n\nGo on.\n\nThe user has now allowed"))
    }

    @Test func aFollowUpWithNothingGrantedIsAsItWas() {
        #expect(PromptBuilder.followUpPrompt(feedback: "x", granted: []) == PromptBuilder.followUpPrompt(feedback: "x"))
        #expect(!PromptBuilder.followUpPrompt(feedback: "x").contains("now allowed"))
    }
}

@Suite struct GrantHintsTests {
    private func prompt(_ fx: RunnerFixture, _ id: String, turn: Int) throws -> String {
        try String(contentsOf: fx.project.promptURL(id, turn: turn), encoding: .utf8)
    }

    @Test func theTurnAfterAGrantIsToldAboutItAndAOnceGrantIsToldOnlyOnce() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        try await denyInLog(fx, id, ["chmod +x scripts/x.sh"])
        _ = try await fx.service.grant(id: id, target: "1", scope: .once)

        _ = try await fx.runner(id).run(fx.options(feedback: "Go on."))
        let second = try prompt(fx, id, turn: 2)
        #expect(second.contains("The user has now allowed these commands"), "\(second)")
        #expect(second.contains("Bash(chmod +x scripts/x.sh)"))

        _ = try await fx.runner(id).run(fx.options(feedback: "And again."))
        #expect(!(try prompt(fx, id, turn: 3)).contains("now allowed"))
    }

    @Test func aTurnWithNoGrantsGetsTheUsualFollowUp() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        _ = try await fx.runner(id).run(fx.options())
        _ = try await fx.runner(id).run(fx.options(feedback: "Go on."))
        #expect(!(try prompt(fx, id, turn: 2)).contains("now allowed"))
    }
}

@Suite struct GrantHintCLITests {
    private func cli(_ arguments: [String], in fx: RunnerFixture, fake: String = "") async throws -> (
        text: String, exit: ProcessExit?
    ) {
        var spawn = SpawnRequest(
            executable: WorkbenchBinary.executable, arguments: arguments,
            environment: ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "USER": NSUserName(), "FAKE_CLAUDE": fake],
            workingDirectory: fx.repo, timeout: 60)
        spawn.snapshotInterval = 3600
        let run = try ProcessRunner.start(spawn)
        var lines: [String] = []
        var exit: ProcessExit?
        for await event in run.events {
            if case .line(let line) = event { lines.append(line) }
            if case .exited(let e) = event { exit = e }
        }
        return (lines.joined(separator: "\n"), exit)
    }

    @Test func runAndReviewPointAtGrantWhenSomethingWasDenied() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        let denied = try await cli(["run"], in: fx, fake: "deny=chmod +x scripts/x.sh")
        #expect(denied.exit?.termination == .exited(0), "\(denied.text)")
        #expect(denied.text.contains("1 denied"), "\(denied.text)")
        #expect(denied.text.contains("`workbench grant` lists what was denied"), "\(denied.text)")

        let review = try await cli(["review", id], in: fx)
        #expect(review.text.contains("allow one with `workbench grant \(id)`"), "\(review.text)")
    }

    @Test func aTurnWithNothingDeniedSaysNothingAboutGrant() async throws {
        let fx = try await RunnerFixture()
        _ = try await fx.approvedThread()
        let quiet = try await cli(["run"], in: fx)
        #expect(!quiet.text.contains("workbench grant"), "\(quiet.text)")
    }
}
