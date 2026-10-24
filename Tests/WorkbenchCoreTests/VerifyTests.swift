import Foundation
import Testing

@testable import WorkbenchCore

/// A thread's log as an older Workbench wrote a verify step: `verify.started`, one `proof.added` per file (a `/` in a name
/// makes folders), `verify.ended`. Workbench no longer runs one, and nothing that reads the log uses it: an old log
/// with one must still load, and its files are never proof.
func recordLegacyVerify(
    _ fx: RunnerFixture, _ id: String, _ files: [String: String], turn: Int = 1
) async throws {
    let proof = fx.project.proofDirectory(id, turn: turn)
    try FileManager.default.createDirectory(at: proof, withIntermediateDirectories: true)
    for (name, text) in files {
        let url = proof.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    let worktree = fx.project.worktreesDirectory.appendingPathComponent(id)
    let identity = await ProofIdentity.of(worktree: worktree, git: fx.git, attributesFrom: nil)
    let commit: JSONValue = identity.map { .string($0.commit) } ?? .null
    let tree: JSONValue = identity.map { .string($0.tree) } ?? .null
    let log = try EventLogWriter.open(at: fx.project.eventsURL(id))
    try await log.append(
        .verifyStarted, turn: turn,
        data: [
            "command": "scripts/verify.sh", "proof_ref": .string(Project.proofRef(turn: turn)),
            "commit": commit, "tree": tree,
        ])
    let recorded = ProofCollector.collect(proofDirectory: proof, threadDirectory: fx.project.threadDirectory(id)).files
    for file in recorded {
        try await log.append(
            .proofAdded, turn: turn,
            data: [
                "name": .string(file.name), "path": .string(file.path), "sha256": .string(file.sha256),
                "bytes": .int(file.bytes), "commit": commit, "tree": tree,
            ])
    }
    try await log.append(
        .verifyEnded, turn: turn,
        data: ["result": "passed", "command": "scripts/verify.sh", "exit_code": 0, "duration_ms": 10,
            "proof_files": .int(recorded.count)])
    await log.close()
}

@Suite(.processGate) struct ProofCollectorTests {
    @Test func collectingProofIsBoundedInEntriesFileSizeAndTotalBytes() throws {
        let dir = Scratch.url("proof")
        let thread = dir.appendingPathComponent("thread")
        let proof = thread.appendingPathComponent("proof/turn-1")
        try FileManager.default.createDirectory(at: proof, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for (name, size) in [("a.png", 10), ("b.png", 10), ("big.png", 100), ("c.png", 10)] {
            try Data(repeating: 1, count: size).write(to: proof.appendingPathComponent(name))
        }

        let all = ProofCollector.collect(proofDirectory: proof, threadDirectory: thread)
        #expect(all.files.map(\.name) == ["a.png", "b.png", "big.png", "c.png"])
        #expect(all.files.first?.path == "proof/turn-1/a.png")

        let bigSkipped = ProofCollector.collect(proofDirectory: proof, threadDirectory: thread, maxFileBytes: 50)
        #expect(bigSkipped.files.map(\.name) == ["a.png", "b.png", "c.png"])
        #expect(bigSkipped.omitted == 1)

        let totalCapped = ProofCollector.collect(
            proofDirectory: proof, threadDirectory: thread, maxFileBytes: 50, maxTotalBytes: 20)
        #expect(totalCapped.files.map(\.name) == ["a.png", "b.png"])
        #expect(totalCapped.omitted == 2)

        let fewEntries = ProofCollector.collect(proofDirectory: proof, threadDirectory: thread, maxEntries: 2)
        #expect(fewEntries.files.count <= 2)
        #expect(fewEntries.omitted >= 1)

        let many = proof.deletingLastPathComponent().appendingPathComponent("many")
        try FileManager.default.createDirectory(at: many, withIntermediateDirectories: true)
        for i in 0..<40 { try Data([1]).write(to: many.appendingPathComponent("f\(i).png")) }
        let capped = ProofCollector.collect(proofDirectory: many, threadDirectory: thread, maxEntries: 10)
        #expect(capped.files.count <= 10, "the walk stops at the entry limit")
        #expect(capped.omitted >= 1)

        let noTime = ProofCollector.collect(proofDirectory: proof, threadDirectory: thread, budget: -1)
        #expect(noTime.files.isEmpty)
        #expect(noTime.omitted >= 1)
    }
}

@Suite(.processGate) struct LogFollowTests {
    private func event(_ kind: EventKind, _ result: String? = nil) -> Event {
        Event(seq: 1, ts: "t", turn: 1, kind: kind, data: result.map { ["result": .string($0)] } ?? [:])
    }

    private func ends(
        _ kind: EventKind, _ result: String? = nil, checks: Bool = false, verifiers: Bool = false,
        succeeded: Bool = true
    ) -> Bool {
        LogFormatter.followEnds(
            event(kind, result), sawStart: true, checks: checks, turnSucceeded: succeeded,
            verifiers: verifiers)
    }

    @Test func followingWaitsForTheVerifierOfASuccessfulTurn() {
        #expect(!ends(.turnEnded, "succeeded", checks: true, verifiers: true))
        #expect(!ends(.checkRan, "passed", checks: true, verifiers: true))
        #expect(ends(.verifierEnded, checks: true, verifiers: true))
        #expect(!ends(.turnEnded, "succeeded", verifiers: true), "no check: the verifier still follows the turn")
    }

    @Test func aTurnThatDidNotSucceedOrWasStoppedEndsAtItsCheckOrItself() {
        #expect(ends(.checkRan, "failed", checks: true, verifiers: true, succeeded: false))
        #expect(ends(.turnEnded, "stopped", verifiers: true, succeeded: false))
        #expect(ends(.checkRan, "failed", checks: true, verifiers: true), "a failing check ends the follow")
    }

    @Test func joiningAtAnOpenCheckKnowsTheTurnSucceeded() {
        func turnEnded(_ result: String) -> Event { event(.turnEnded, result) }
        #expect(LogFormatter.latestTurnSucceeded([turnEnded("failed"), turnEnded("succeeded")]))
        #expect(!LogFormatter.latestTurnSucceeded([turnEnded("succeeded"), turnEnded("failed")]))
        #expect(!LogFormatter.latestTurnSucceeded([]))
    }

    @Test func withoutAVerifierNothingChanges() {
        #expect(ends(.turnEnded, "succeeded"))
        #expect(!ends(.turnEnded, "succeeded", checks: true))
        #expect(ends(.checkRan, "passed", checks: true))
    }
}

@Suite(.processGate) struct VerifyPromptTests {
    private func goal(_ proof: String) throws -> Goal {
        let text = """
            ---
            id: g-1
            title: T
            base: main
            budget_usd: 1
            turn_timeout_min: 5
            ---

            ## Request

            Do it.

            ## Criteria

            - [c1] It shows.
              - proof: \(proof)

            ## Out of scope

            - Nothing.
            """
        return try GoalFile.parse(text).goal
    }

    @Test func claudeIsToldWhichCriteriaTheVerifierCovers() throws {
        let prompt = PromptBuilder.firstPrompt(
            goal: try goal("screenshot: home"), checkCommand: nil, verifies: true)
        #expect(prompt.contains("## Verification"))
        #expect(prompt.contains("`screenshot: <name>`"))
        #expect(prompt.contains("do not need to take"))
    }

    @Test func nothingIsAddedWithoutAVerifierOrAScreenshotCriterion() throws {
        let shot = try goal("screenshot: home")
        #expect(!PromptBuilder.firstPrompt(goal: shot, checkCommand: nil, verifies: false).contains("Verification"))
        let other = try goal("`swift test` passes")
        #expect(!PromptBuilder.firstPrompt(goal: other, checkCommand: nil, verifies: true).contains("Verification"))
    }
}

@Suite(.processGate) struct RemovedVerifyConfigTests {
    @Test(arguments: ["verify_command = \"scripts/verify.sh\"", "verify_timeout_min = 20"])
    func theOldVerifyKeysAreRefusedWithAMessageThatNamesTheReplacement(line: String) throws {
        let error = try #require(throws: ConfigError.self) {
            try Config.parse("\(line)\n[tools]\navailable = [\"Read\"]\n")
        }
        let problem = try #require(error.problems.first)
        #expect(problem.line == 1)
        #expect(problem.message.contains("was removed: replace it with a [verifier] table"))
        #expect(!problem.message.contains("unknown key"))
    }

    @Test func aConfigWithOnlyAVerifierTableStillParses() throws {
        let config = try Config.parse("[verifier]\nmodel = \"sonnet\"\n[tools]\navailable = [\"Read\"]\n")
        #expect(config.verifier != nil)
    }

    @Test func anOldLogWithAVerifyStepStillReads() {
        let events = [
            Event(seq: 1, ts: "t", turn: 1, kind: .verifyStarted, data: ["command": "scripts/verify.sh"]),
            Event(seq: 2, ts: "t", turn: 1, kind: .verifyEnded, data: ["result": "passed", "duration_ms": 3000]),
        ]
        #expect(LogFormatter.describe(events[0]).contains("verify started: scripts/verify.sh"))
        #expect(LogFormatter.describe(events[1]).contains("verify passed"))
    }
}
