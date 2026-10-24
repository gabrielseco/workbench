import Foundation
import Testing

@testable import WorkbenchCore

/// The head of a PNG, enough for its size to be read: signature, then an IHDR of `width` x `height`.
private func png(_ width: Int, _ height: Int, tag: String = "") -> Data {
    func big(_ n: Int) -> [UInt8] { [UInt8(n >> 24 & 255), UInt8(n >> 16 & 255), UInt8(n >> 8 & 255), UInt8(n & 255)] }
    var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + big(13) + Array("IHDR".utf8)
    bytes += big(width) + big(height) + [8, 6, 0, 0, 0]
    return Data(bytes) + Data(tag.utf8)
}

func recordVerifierProof(
    _ fx: RunnerFixture, _ id: String, _ files: [String: String], turn: Int = 1
) async throws {
    try await recordVerifierProof(fx, id, files.mapValues { Data($0.utf8) }, turn: turn)
}

/// Writes `files` into the turn's proof folder and records them as the verifier's: `proof.added` for each PNG, at the
/// work as it is now, between `verifier.started` and `verifier.ended`, as `VerifierRun` does. A rerun records only what
/// it wrote again.
func recordVerifierProof(
    _ fx: RunnerFixture, _ id: String, _ files: [String: Data], turn: Int = 1
) async throws {
    let proof = fx.project.proofDirectory(id, turn: turn)
    try FileManager.default.createDirectory(at: proof, withIntermediateDirectories: true)
    for (name, data) in files {
        let url = proof.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
    let worktree = fx.project.worktreesDirectory.appendingPathComponent(id)
    let identity = await ProofIdentity.of(worktree: worktree, git: fx.git, attributesFrom: nil)
    let commit: JSONValue = identity.map { .string($0.commit) } ?? .null
    let tree: JSONValue = identity.map { .string($0.tree) } ?? .null
    let recorded = ProofCollector.collect(proofDirectory: proof, threadDirectory: fx.project.threadDirectory(id)).files
    let log = try EventLogWriter.open(at: fx.project.eventsURL(id))
    try await log.append(.verifierStarted, turn: turn, data: ["argv": ["claude"]])
    for file in recorded where files[file.name] != nil && file.name.hasSuffix(".png") {
        try await log.append(
            .proofAdded, turn: turn,
            data: [
                "name": .string(file.name), "path": .string(file.path), "sha256": .string(file.sha256),
                "bytes": .int(file.bytes), "commit": commit, "tree": tree, "source": "verifier",
            ])
    }
    try await log.append(.verifierEnded, turn: turn, data: ["ok": true, "report": "c1: holds"])
    await log.close()
}

private func stage(_ r: ReviewedPR) async throws -> PRReviewResult {
    try await r.fx.service.reviewStage(
        named: "design", id: r.id, config: r.config, codexPath: r.codex.path, environment: r.codex.environment(),
        timeout: 30, capacityBackoff: { _ in 0 })
}

private let designStage = """

    [review]
    stages = ["pr-review", "design"]
    [review.stage.design]
    inputs = ["diff", "goal", "proof"]

    """

// MARK: what a verifier run records

@Suite(.processGate) struct VerifierRecordsProofTests {
    @Test func everyPNGItLeavesIsProofAndOtherFilesAreOnlyListed() async throws {
        let v = try await VerifierFixture()
        let report = try await v.verify("proof=shot.png")
        #expect(report.files.map(\.name) == ["shot.png"])
        let events = try v.fx.events(v.id)
        let added = events.filter { $0.kind == .proofAdded }
        #expect(added.count == 1)
        let one = try #require(added.first)
        #expect(one.data["name"]?.stringValue == "shot.png" && one.data["source"]?.stringValue == "verifier")
        #expect(one.data["path"]?.stringValue == "proof/turn-1/shot.png" && one.data["sha256"]?.stringValue?.count == 64)
        #expect(one.data["commit"]?.stringValue?.count == 40 && one.data["tree"]?.stringValue?.count == 40)
        // Between the start and the end of the run, so the log reads as one piece.
        let order = events.map(\.kind.rawValue).filter { ["verifier.started", "proof.added", "verifier.ended"].contains($0) }
        #expect(order == ["verifier.started", "proof.added", "verifier.ended"])

        let verifier = try #require(ThreadState.derive(from: events, id: v.id).review.verifier)
        #expect(verifier.proof.map(\.name) == ["shot.png"] && verifier.ok && !verifier.report.isEmpty)
    }

    @Test func aFileThatIsNotAPNGIsListedButNotRecordedAsProof() async throws {
        let v = try await VerifierFixture()
        let report = try await v.verify("proof=notes.txt")
        #expect(report.files.map(\.name) == ["notes.txt"])
        #expect(try v.fx.events(v.id).filter { $0.kind == .proofAdded }.isEmpty)
    }

    @Test func aFailedRunStillRecordsTheScreenshotsItLeftAndSaysItFailed() async throws {
        let v = try await VerifierFixture()
        // The fake writes its file before it errors, as a run that took a screenshot and then ran out of budget would.
        let report = try await v.verify("proof=shot.png,budget-stop")
        #expect(!report.ok && report.files.map(\.name) == ["shot.png"])
        let events = try v.fx.events(v.id)
        #expect(events.filter { $0.kind == .proofAdded }.count == 1)
        let verifier = try #require(ThreadState.derive(from: events, id: v.id).review.verifier)
        #expect(!verifier.ok && verifier.proof.map(\.name) == ["shot.png"] && verifier.reason?.contains("budget") == true)
        let set = try #require(Review.ProofSet(verifier: verifier))
        #expect(set.source == "verifier did not finish", "a person is told the run did not finish")
    }
}

// MARK: what reads it

@Suite(.processGate) struct VerifierProofReadersTests {
    @Test func theDesignStageIsGivenTheVerifiersPNGsWithTheirSizesAndTheLogNamesThem() async throws {
        let r = try await reviewedPR(extraConfig: designStage)
        let files = ["home.png": "pixels", "dark.png": "night", "min.png": "small", "notes.txt": "x"]
        try await recordVerifierProof(r.fx, r.id, files)

        let result = try await stage(r)
        #expect(result.verdict == .clean, "\(result.failure ?? "")")
        let proof = r.fx.project.proofDirectory(r.id, turn: 1)
        let brief = try #require(r.codex.read("brief_1"))
        for name in ["home.png", "dark.png", "min.png"] {
            #expect(brief.contains("- \(proof.appendingPathComponent(name).path)"), "\(name)")
        }
        #expect(!brief.contains("notes.txt"))
        let call = try #require(r.codex.calls.first)
        #expect(call.contains("-i \(proof.appendingPathComponent("min.png").path)"), "\(call)")
        let started = try #require(
            try r.fx.events(r.id).first { $0.kind == .reviewStageStarted && $0.data["stage"]?.stringValue == "design" })
        guard case .array(let given)? = started.data["proof"] else {
            Issue.record("proof missing")
            return
        }
        #expect(Set(given.compactMap(\.stringValue)) == ["home.png", "dark.png", "min.png"])
    }

    @Test func theStageBriefGivesEachImagesPixelSize() async throws {
        let r = try await reviewedPR(extraConfig: designStage)
        let files: [String: Data] = ["wide.png": png(2000, 1304), "min.png": png(1000, 600), "bad.png": Data("x".utf8)]
        try await recordVerifierProof(r.fx, r.id, files)
        _ = try await stage(r)
        let brief = try #require(r.codex.read("brief_1"))
        #expect(brief.contains("wide.png (2000 × 1304 px)") && brief.contains("min.png (1000 × 600 px)"), "\(brief)")
        #expect(brief.contains("bad.png\n"), "a size that cannot be read is left out, the image is still given")
    }

    @Test func aStageIsGivenNoMoreImagesThanItsLimit() async throws {
        let r = try await reviewedPR(extraConfig: designStage)
        var files: [String: Data] = [:]
        for i in 0..<(PRReview.proofLimit + 5) { files[String(format: "shot-%02d.png", i)] = png(10 + i, 20, tag: "\(i)") }
        try await recordVerifierProof(r.fx, r.id, files)
        _ = try await stage(r)
        let call = try #require(r.codex.calls.first)
        #expect(call.components(separatedBy: " -i ").count - 1 == PRReview.proofLimit, "\(call)")
        let started = try #require(try r.fx.events(r.id).first { $0.kind == .reviewStageStarted && $0.data["stage"] != nil })
        guard case .array(let given)? = started.data["proof"] else {
            Issue.record("proof missing")
            return
        }
        #expect(given.count == PRReview.proofLimit)
    }

    @Test func theJudgeIsToldEachImagesSizeAndGivenNoMoreThanItsLimit() async throws {
        let fx = try await RunnerFixture()
        let (id, _) = try await acceptedThread(fx)
        var files: [String: Data] = [:]
        let count = ThreadService.judgeScreenshotLimit + 3
        for i in 0..<count { files[String(format: "s-%02d.png", i)] = png(300 + i, 200, tag: "\(i)") }
        try await recordVerifierProof(fx, id, files)
        let dir = fx.repo.deletingLastPathComponent().appendingPathComponent("judge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let answer = dir.appendingPathComponent("a.json")
        try #"{"criteria": [{"id": "c1", "met": true, "evidence": ["x"]}], "concerns": []}"#
            .write(to: answer, atomically: true, encoding: .utf8)
        let dump = dir.appendingPathComponent("dump.json").path
        _ = try await fx.service.judge(
            id: id, config: try Config.load(from: fx.project.configURL),
            environment: ["PATH": "/usr/bin:/bin", "FAKE_CLAUDE": "answer=\(answer.path),dump=\(dump)"])
        let text = try String(contentsOfFile: dump, encoding: .utf8)
        let listed = text.components(separatedBy: " px)").count - 1
        #expect(listed == ThreadService.judgeScreenshotLimit, "\(listed) images listed")
        #expect(text.contains("s-00.png (300 × 200 px)"))
    }

    @Test func aSecondRunThatFailsKeepsTheTurnsProof() async throws {
        let v = try await VerifierFixture()
        _ = try await v.verify("proof=shot.png")
        let first = try #require(ThreadState.derive(from: try v.fx.events(v.id), id: v.id).review.verifier)
        #expect(first.proof.map(\.name) == ["shot.png"])

        // A run again that dies before it writes anything: the earlier file is still on disk and still the proof.
        let failed = try await v.verify("crash-after=1", again: true)
        #expect(!failed.ok && failed.files.isEmpty)
        let after = try #require(ThreadState.derive(from: try v.fx.events(v.id), id: v.id).review.verifier)
        #expect(!after.ok && after.proof == first.proof)
        let thread = v.fx.project.threadDirectory(v.id)
        let status = CriteriaStatus.evaluate(
            criteria: [Criterion(id: "c1", text: "t", proof: "screenshot: shot")], check: nil, lastTurn: 1,
            verifier: after, proofAvailable: { $0.isAvailable(in: thread) })
        #expect(status[0].state == .evidence)
    }

    @Test func theStageIsGivenOnlyTheVerifiersFilesNotAnOldVerifyStepsOnes() async throws {
        let r = try await reviewedPR(extraConfig: designStage)
        try await recordLegacyVerify(r.fx, r.id, ["step.png": "a"])
        try await recordVerifierProof(r.fx, r.id, ["seen.png": "pixels"])
        _ = try await stage(r)
        let started = try #require(try r.fx.events(r.id).first { $0.kind == .reviewStageStarted && $0.data["stage"] != nil })
        guard case .array(let given)? = started.data["proof"] else {
            Issue.record("proof missing")
            return
        }
        #expect(Set(given.compactMap(\.stringValue)) == ["seen.png"])
    }

    @Test func aStageWithNoVerifierRunFailsTheRoundAndSaysSo() async throws {
        let r = try await reviewedPR(extraConfig: designStage)
        // An old log's verify step is not proof: the round still has none.
        try await recordLegacyVerify(r.fx, r.id, ["step.png": "a"])
        let result = try await stage(r)
        #expect(result.verdict == nil && result.failure?.contains("no verifier run on record") == true)
        #expect(result.failure?.contains("verify step") == false)
        #expect(r.codex.runs == 0)
    }

    @Test func theJudgeReadsTheVerifiersScreenshotsInTheirFolder() async throws {
        let fx = try await RunnerFixture()
        let (id, _) = try await acceptedThread(fx)
        try await recordVerifierProof(fx, id, ["seen.png": "pixels", "second.png": "more"])
        let dir = fx.repo.deletingLastPathComponent().appendingPathComponent("judge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let answer = dir.appendingPathComponent("a.json")
        try #"{"criteria": [{"id": "c1", "met": true, "evidence": ["x"]}], "concerns": []}"#
            .write(to: answer, atomically: true, encoding: .utf8)
        let dump = dir.appendingPathComponent("dump.json").path
        _ = try await fx.service.judge(
            id: id, config: try Config.load(from: fx.project.configURL),
            environment: ["PATH": "/usr/bin:/bin", "FAKE_CLAUDE": "answer=\(answer.path),dump=\(dump)"])
        let argv = try String(contentsOfFile: dump, encoding: .utf8)
        #expect(argv.contains("seen.png") && argv.contains("second.png"), "the prompt lists every screenshot")
        #expect(argv.contains("\"Read\""))
        #expect(argv.contains(OrphanSweeper.realPath(fx.project.proofDirectory(id, turn: 1))), "it runs where they are")
    }

    @Test func aScreenshotProofIsProducibleWithAVerifierAndNotWithNothing() throws {
        let criterion = Criterion(id: "c1", text: "t", proof: "screenshot: home")
        let goalText = """
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

            - [c1] t
              - proof: \(criterion.proof)

            ## Out of scope

            - none
            """
        let goal = try GoalFile.parse(goalText).goal
        let none = try Config.parse("[verifier]\nenabled = false\n[tools]\navailable = [\"Read\"]\n")
        let with = try Config.parse("[tools]\navailable = [\"Read\"]\n[verifier]\nskill = \"s.md\"\n")
        let reason = ProofCommands.warnings(goal: goal, config: none).first?.reason
        #expect(reason?.contains("no verifier skill") == true)
        #expect(ProofCommands.warnings(goal: goal, config: with).isEmpty)
    }

    @Test func theFirstPromptOnlyPromisesWhatWillRun() throws {
        func prompt(_ config: String) throws -> String {
            let goal = try GoalFile.parse(
                """
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

                - [c1] t
                  - proof: screenshot: home

                ## Out of scope

                - none
                """
            ).goal
            let c = try Config.parse("[tools]\navailable = [\"Read\"]\n" + config)
            return PromptBuilder.firstPrompt(
                goal: goal, checkCommand: nil, instructions: nil,
                verifies: c.verifier != nil, plan: nil)
        }
        #expect(try prompt("[verifier]\nskill = \"s.md\"\n").contains("Workbench runs the project's verifier itself"))
        #expect(try !prompt("[verifier]\nenabled = false\n").contains("Workbench runs the project's verifier"))
    }
}
