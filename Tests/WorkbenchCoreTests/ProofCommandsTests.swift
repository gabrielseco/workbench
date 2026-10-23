import Foundation
import Testing

@testable import WorkbenchCore

private func goal(proofs: [String], outOfScope: String = "- Nothing else.") throws -> Goal {
    let criteria = proofs.enumerated().map { "- [c\($0.offset + 1)] Something holds.\n  - proof: \($0.element)" }
        .joined(separator: "\n")
    return try GoalFile.parse(
        """
        ---
        id: g-2026-10-14-x
        title: X
        base: main
        budget_usd: 5
        turn_timeout_min: 30
        ---

        ## Request

        Do it.

        ## Criteria

        \(criteria)

        ## Out of scope

        \(outOfScope)
        """
    ).goal
}

private func config(allowed: [String], denied: [String] = [], check: String? = nil, bash: Bool = true) throws -> Config {
    let list = { (items: [String]) in items.map { "\"\($0)\"" }.joined(separator: ", ") }
    return try Config.parse(
        """
        \(check.map { "check_command = \"\($0)\"" } ?? "")
        [tools]
        available = [\(bash ? "\"Read\", \"Bash\"" : "\"Read\"")]
        allowed = [\(list(allowed))]
        denied = [\(list(denied))]
        """)
}

@Suite(.processGate) struct ProofCommandsTests {
    @Test func aCommandTheAllowlistLacksIsNamedWithTheEntryThatWouldFixIt() throws {
        let g = try goal(proofs: ["`mix api.contract.check` passes", "`mix format --check-formatted` is clean"])
        let c = try config(allowed: ["Read", "Bash(mix test:*)"])
        let warnings = ProofCommands.warnings(goal: g, config: c)
        #expect(warnings.map(\.criterion) == ["c1", "c2"])
        #expect(warnings[0].command == "mix api.contract.check")
        #expect(warnings[0].suggestion == "Bash(mix api.contract.check:*)")
        #expect(warnings[0].line.contains("[tools] allowed"))
    }

    @Test func anAllowedCommandAndItsArgumentsAreFine() throws {
        let g = try goal(proofs: ["`mix test test/api` passes", "`mix test` passes"])
        let c = try config(allowed: ["Bash(mix test:*)"])
        #expect(ProofCommands.warnings(goal: g, config: c).isEmpty)
    }

    @Test func aPrefixIsAWordBoundaryNotACharacterPrefix() throws {
        let g = try goal(proofs: ["`mix testing` passes"])
        let c = try config(allowed: ["Bash(mix test:*)"])
        #expect(ProofCommands.warnings(goal: g, config: c).count == 1)
    }

    @Test func aDeniedCommandSaysWhichPatternDeniesIt() throws {
        let g = try goal(proofs: ["`git push origin main` happened"])
        let c = try config(allowed: ["Bash(git:*)"], denied: ["Bash(git push:*)"])
        let warning = try #require(ProofCommands.warnings(goal: g, config: c).first)
        #expect(warning.reason.contains("denied by `Bash(git push:*)`"))
        #expect(warning.suggestion == nil)
    }

    @Test func theCheckCommandIsAllowedBecauseTheRunnerAddsIt() throws {
        let g = try goal(proofs: ["`scripts/check.sh` passes"])
        let c = try config(allowed: ["Read"], check: "scripts/check.sh")
        #expect(ProofCommands.warnings(goal: g, config: c).isEmpty)
    }

    @Test func aScriptInTheRepositoryIsACommandEvenWhenNothingMentionsIt() throws {
        let g = try goal(proofs: ["`./scripts/verify.sh` exits 0"])
        let c = try config(allowed: ["Read"])
        #expect(ProofCommands.warnings(goal: g, config: c).map(\.command) == ["./scripts/verify.sh"])
    }

    @Test func codeIdentifiersAndPlainWordsAreNotCommands() throws {
        let g = try goal(proofs: ["test `SyncClientTests.retries*` and `SyncClient.fetch` used", "screenshot of Settings"])
        let c = try config(allowed: ["Bash(swift test:*)"])
        #expect(ProofCommands.warnings(goal: g, config: c).isEmpty)
    }

    @Test func withoutBashEveryCommandProofIsUnrunnable() throws {
        let g = try goal(proofs: ["`swift test` passes"])
        let c = try config(allowed: ["Bash(swift test:*)"], bash: false)
        #expect(ProofCommands.warnings(goal: g, config: c).first?.reason == "the Bash tool is not available")
    }

    @Test func eachPartOfACompoundCommandIsJudgedOnItsOwn() throws {
        let g = try goal(proofs: ["`mix test && git push origin main` is clean"])
        let c = try config(allowed: ["Bash(mix test:*)", "Bash(git status:*)"], denied: ["Bash(git push:*)"])
        let warnings = ProofCommands.warnings(goal: g, config: c)
        #expect(warnings.map(\.command) == ["git push origin main"])
        #expect(warnings[0].reason.contains("denied by `Bash(git push:*)`"))
        let allFine = try goal(proofs: ["`mix test | mix test --failed`"])
        #expect(ProofCommands.warnings(goal: allFine, config: try config(allowed: ["Bash(mix test:*)"])).isEmpty)
    }

    @Test func theSameCommandTwiceInOneProofIsSaidOnce() throws {
        let g = try goal(proofs: ["`mix format` then `mix format` again"])
        let c = try config(allowed: ["Bash(mix test:*)"])
        #expect(ProofCommands.warnings(goal: g, config: c).count == 1)
    }
}

@Suite(.processGate) struct OutOfScopeContinuationTests {
    @Test func anIndentedLineWrapsTheBulletAboveIt() throws {
        let g = try goal(
            proofs: ["`x` passes"],
            outOfScope: "- Changing the request timeout, which\n  the client reads from settings.\n- Retrying uploads.")
        #expect(g.outOfScope == ["Changing the request timeout, which the client reads from settings.", "Retrying uploads."])
    }

    @Test func aLineThatIsNotIndentedOrFollowsNoBulletIsStillAnError() throws {
        #expect(throws: GoalParseError.self) {
            _ = try goal(proofs: ["`x` passes"], outOfScope: "- One.\nstray words")
        }
        #expect(throws: GoalParseError.self) {
            _ = try goal(proofs: ["`x` passes"], outOfScope: "  indented but nothing above")
        }
    }
}

@Suite(.processGate) struct GoalApproveWarningTests {
    @Test func approveNamesAProofTheAllowlistWouldDenyAndApprovesOnlyWithTheFlag() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.service.newThread(name: "proof", base: "main")
        let url = fx.project.goalURL(id)
        var text = try String(contentsOf: url, encoding: .utf8)
        let fills = [
            ("TODO(workbench): say what should change, in a few sentences.", "Add a greeting."),
            ("TODO(workbench): something that can be checked.", "The script passes."),
            ("TODO(workbench): how it will be shown (a test, a command, a screenshot).", "`./scripts/verify.sh` exits 0"),
            ("TODO(workbench): what must not change.", "Other files."),
        ]
        for (placeholder, value) in fills { text = text.replacingOccurrences(of: placeholder, with: value) }
        try text.write(to: url, atomically: true, encoding: .utf8)

        var spawn = SpawnRequest(
            executable: WorkbenchBinary.executable, arguments: ["goal", "approve", "--allow-unrunnable-proofs", id],
            environment: ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "USER": NSUserName()],
            workingDirectory: fx.repo, timeout: 60)
        spawn.snapshotInterval = 3600
        var lines: [String] = []
        var exit: ProcessExit?
        for await event in try ProcessRunner.start(spawn).events {
            if case .line(let line) = event { lines.append(line) }
            if case .exited(let e) = event { exit = e }
        }
        #expect(exit?.termination == .exited(0))
        #expect(lines.contains("approved \(id)"))
        let warning = try #require(lines.first { $0.hasPrefix("warning:") })
        #expect(warning.contains("[c1]") && warning.contains("./scripts/verify.sh") && warning.contains("[tools] allowed"))
        #expect(try GoalFile.parse(String(contentsOf: url, encoding: .utf8)).goal.approval == .approved)

        // Approving again says it is approved and still names the proof: the config is not in the hash.
        var again: [String] = []
        for await event in try ProcessRunner.start(spawn).events {
            if case .line(let line) = event { again.append(line) }
        }
        #expect(again.contains { $0.contains("already approved") })
        #expect(again.contains { $0.hasPrefix("warning:") && $0.contains("./scripts/verify.sh") })
    }
}
