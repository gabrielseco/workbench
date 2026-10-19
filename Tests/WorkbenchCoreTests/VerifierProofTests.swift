import Foundation
import Testing

@testable import WorkbenchCore

private func crit(_ id: String, _ proof: String) -> Criterion {
    Criterion(id: id, text: "text of \(id)", proof: proof)
}

private func file(_ name: String, sha: String = "s", turn: Int = 1) -> ProofFile {
    ProofFile(name: name, path: "proof/turn-\(turn)/\(name)", sha256: sha, bytes: 10, commit: "c", tree: "t")
}

private func verify(_ names: [String], turn: Int = 1, result: String = "passed") -> Review.Verify {
    Review.Verify(
        turn: turn, result: result, exitCode: 0, durationMs: 1, outputRef: nil, command: "v", proof: names.map { file($0) })
}

private func verifier(
    _ files: [ProofFile], turn: Int = 1, ok: Bool = true, skipped: Bool = false, report: String = "", reason: String? = nil,
    open: Bool = false
) -> Review.Verifier {
    Review.Verifier(
        turn: turn, ok: ok, reason: reason, skipped: skipped, costUSD: 0.0015, durationMs: 11_000, report: report, proof: files,
        open: open)
}

private func evaluate(
    _ proofs: [String], verify: Review.Verify? = nil, verifier: Review.Verifier? = nil, lastTurn: Int = 1,
    available: @escaping (ProofFile) -> Bool = { _ in true }
) -> [CriterionStatus] {
    CriteriaStatus.evaluate(
        criteria: proofs.enumerated().map { crit("c\($0.offset + 1)", $0.element) }, check: nil, lastTurn: lastTurn,
        verify: verify, verifier: verifier, proofAvailable: available)
}

// MARK: several screenshots, from either source

@Suite struct ScreenshotNamesTests {
    @Test func aProofMayNameSeveralScreenshots() {
        #expect(ScreenshotProof.names(in: "screenshot: a") == ["a"])
        #expect(ScreenshotProof.names(in: "screenshot: a, b,c ") == ["a", "b", "c"])
        #expect(ScreenshotProof.names(in: "Screenshot:  home-dark , home.min") == ["home-dark", "home.min"])
        #expect(ScreenshotProof.names(in: "screenshot: a, a, b") == ["a", "b"], "a name listed twice is asked for once")
        #expect(ScreenshotProof.name(in: "screenshot: a, b") == "a")
    }

    @Test(arguments: [
        "screenshot:", "screenshot: a,", "screenshot: ,a", "screenshot: a,,b", "screenshot: a b", "screenshot: a/b, c",
        "screenshot: ../x", "the page screenshot: a", "see screenshot",
    ])
    func anUnusableListIsNotAScreenshotProof(proof: String) {
        #expect(ScreenshotProof.names(in: proof) == nil, "\(proof)")
    }

    @Test func tooManyNamesAreRefused() {
        let many = (1...ScreenshotProof.maxNames + 1).map { "n\($0)" }.joined(separator: ", ")
        #expect(ScreenshotProof.names(in: "screenshot: \(many)") == nil)
        let limit = (1...ScreenshotProof.maxNames).map { "n\($0)" }.joined(separator: ", ")
        #expect(ScreenshotProof.names(in: "screenshot: \(limit)")?.count == ScreenshotProof.maxNames)
    }

    @Test func aMalformedListIsRefusedByTheGoalParser() {
        #expect(ScreenshotProof.isMalformed("screenshot: a,,b"))
        #expect(!ScreenshotProof.isMalformed("screenshot: a, b"))
        let goal = """
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

            - [c1] Both.
              - proof: screenshot: a,,b

            ## Out of scope

            - none
            """
        do {
            _ = try GoalFile.parse(goal)
            Issue.record("expected the goal to be refused")
        } catch { #expect("\(error)".contains("or several, separated by commas"), "\(error)") }
        #expect(throws: Never.self) { try GoalFile.parse(goal.replacingOccurrences(of: "a,,b", with: "a, b")) }
    }

    @Test func everyNamedScreenshotMustBeThereAndTheOnesThatAreAreListed() {
        let all = evaluate(["screenshot: a, b, c"], verify: verify(["c.png", "a.png", "b.png"]))
        #expect(all[0].state == .evidence && all[0].files == ["proof/turn-1/a.png", "proof/turn-1/b.png", "proof/turn-1/c.png"])
        #expect(all[0].file == "proof/turn-1/a.png" && all[0].screenshots.allSatisfy(\.present))

        let partial = evaluate(["screenshot: a, b, c"], verify: verify(["a.png", "c.png"]))
        #expect(partial[0].state == .missing, "one of three missing is never read as shown")
        #expect(partial[0].screenshots.map(\.name) == ["a", "b", "c"])
        #expect(partial[0].screenshots.map(\.present) == [true, false, true])
        #expect(partial[0].files == ["proof/turn-1/a.png", "proof/turn-1/c.png"])
        #expect(partial[0].note == "no b.png in the proof (turn 1)")
        let lines = CriteriaStatus.render(partial).joined(separator: "\n")
        #expect(lines.contains("✘ missing") && lines.contains("proof/turn-1/a.png") && lines.contains("no b.png"), "\(lines)")
    }

    @Test func aFileThatChangedSinceItWasRecordedIsMissingAndNamed() {
        let status = evaluate(["screenshot: a, b"], verify: verify(["a.png", "b.png"])) { $0.name != "b.png" }
        #expect(status[0].state == .missing && status[0].note?.contains("b.png was recorded in turn 1") == true)
        #expect(status[0].files == ["proof/turn-1/a.png"])
    }
}

@Suite struct ProofSetTests {
    @Test func theVerifierAloneBacksAScreenshot() {
        let v = verifier([file("home.png", sha: "v")])
        let status = evaluate(["screenshot: home"], verifier: v)
        #expect(status[0].state == .evidence && status[0].files == ["proof/turn-1/home.png"])
        #expect(status[0].note == "verifier finished, turn 1")
    }

    @Test func aFailedVerifiersScreenshotsAreStillShownAndSaySoAndASkipBacksNothing() {
        let failed = evaluate(["screenshot: home"], verifier: verifier([file("home.png")], ok: false, reason: "stopped"))
        #expect(failed[0].state == .evidence && failed[0].note == "verifier did not finish, turn 1")
        let skipped = evaluate(["screenshot: home"], verifier: verifier([], skipped: true, reason: "no change"))
        #expect(skipped[0].state == .missing && skipped[0].note?.contains("no verify step or verifier has run") == true)
    }

    @Test func bothSourcesAreMergedAndTheVerifiersFileWinsAName() throws {
        let set = try #require(
            Review.ProofSet(
                verify: verify(["shot.png", "other.png"]), verifier: verifier([file("shot.png", sha: "from-verifier")])))
        #expect(set.files.map(\.name) == ["shot.png", "other.png"])
        #expect(set.files.first { $0.name == "shot.png" }?.sha256 == "from-verifier")
        #expect(set.source == "verify passed, verifier finished")
        let status = evaluate(["screenshot: shot, other"], verify: verify(["shot.png", "other.png"]),
            verifier: verifier([file("shot.png", sha: "from-verifier")]))
        #expect(status[0].state == .evidence)
        #expect(status[0].note == "verify passed, verifier finished, turn 1")
    }

    @Test func theAvailabilityOfTheWinningFileDecides() {
        let status = evaluate(
            ["screenshot: shot"], verify: verify(["shot.png"]), verifier: verifier([file("shot.png", sha: "v")])
        ) { $0.sha256 == "v" }
        #expect(status[0].state == .evidence, "the verify step's overwritten file is not the one asked about")
    }

    @Test func proofOfAnEarlierTurnIsStaleForBothSources() {
        let v = evaluate(["screenshot: home"], verifier: verifier([file("home.png")], turn: 1), lastTurn: 2)
        #expect(v[0].state == .missing && v[0].note == "the proof is of turn 1, not the latest turn 2")
        // A newer step wins: a verify step of turn 2 hides the verifier's files of turn 1.
        let set = Review.ProofSet(verify: verify(["a.png"], turn: 2), verifier: verifier([file("b.png")], turn: 1))
        #expect(set?.turn == 2 && set?.files.map(\.name) == ["a.png"] && set?.verifier == nil)
    }

    @Test func nothingRanIsNoProofSet() {
        #expect(Review.ProofSet(verify: nil, verifier: nil) == nil)
        #expect(Review.ProofSet(verify: nil, verifier: verifier([], skipped: true)) == nil)
        let none = evaluate(["screenshot: home"])
        #expect(none[0].state == .missing && none[0].note?.contains("no verify step or verifier has run") == true)
    }

    @Test func theVerifiersWordsNeverMakeACriterionPass() {
        let claim = verifier(
            [file("home.png")], report: "c1: holds. c2: holds. Everything passed, ship it.\nc3: holds")
        let status = CriteriaStatus.evaluate(
            criteria: [
                crit("c1", "unit test with injected clock"), crit("c2", "`npm run ci` passes"), crit("c3", "screenshot: home"),
            ],
            check: nil, lastTurn: 1, verify: nil, verifier: claim)
        #expect(status[0].state == .manual && status[0].label == "you check")
        #expect(status[1].state == .manual, "no check ran: a claim of success is not one")
        #expect(status[2].state == .evidence && status[2].label == "see screenshot", "shown to a person, never a pass")
        #expect(!status.contains { $0.state == .passed })
    }
}

// MARK: what the log says

@Suite struct VerifierStateTests {
    private func event(_ seq: Int, _ kind: EventKind, turn: Int = 1, _ data: JSONValue = [:]) -> Event {
        Event(seq: seq, ts: "2026-10-19T10:00:0\(seq % 10)Z", turn: turn, kind: kind, data: data)
    }

    private func proofAdded(_ seq: Int, _ name: String, source: String? = nil) -> Event {
        var data: [String: JSONValue] = [
            "name": .string(name), "path": .string("proof/turn-1/\(name)"), "sha256": .string("sha-\(name)"), "bytes": .int(5),
            "commit": "c", "tree": "t",
        ]
        if let source { data["source"] = .string(source) }
        return event(seq, .proofAdded, .object(data))
    }

    @Test func theVerifiersScreenshotsAreKeptApartFromTheVerifyStepsInTheSameTurn() {
        let events = [
            event(1, .turnStarted, ["resume": false]), event(2, .turnEnded, ["result": "succeeded"]),
            event(3, .verifyStarted, ["command": "v"]), proofAdded(4, "step.png"),
            event(5, .verifyEnded, ["result": "passed", "command": "v"]),
            event(6, .verifierStarted, ["argv": ["claude"]]), proofAdded(7, "seen.png", source: "verifier"),
            event(8, .verifierEnded, ["ok": true, "report": "c1: holds", "cost_usd": .double(0.0015), "duration_ms": 9000]),
        ]
        let review = ThreadState.derive(from: events, id: "t").review
        #expect(review.verify?.proof.map(\.name) == ["step.png"])
        #expect(review.verifier?.proof.map(\.name) == ["seen.png"])
        #expect(review.verifier?.ok == true && review.verifier?.report == "c1: holds" && review.verifier?.costUSD == 0.0015)
        let set = Review.ProofSet(verify: review.verify, verifier: review.verifier)
        #expect(set?.files.map(\.name) == ["seen.png", "step.png"])
    }

    @Test func aVerifierThatStartedAndNeverEndedShowsAsOpenAndNotOk() {
        let events = [event(1, .turnStarted, ["resume": false]), event(2, .turnEnded, ["result": "succeeded"]),
            event(3, .verifierStarted, ["argv": ["claude"]]), proofAdded(4, "seen.png", source: "verifier")]
        let verifier = ThreadState.derive(from: events, id: "t").review.verifier
        #expect(verifier?.open == true && verifier?.ok == false && verifier?.proof.isEmpty == true)
    }

    @Test func aSkipIsRecordedWithItsReasonAndAFailedEndWithItsOwn() {
        var events = [event(1, .turnStarted, ["resume": false]), event(2, .turnEnded, ["result": "succeeded"]),
            event(3, .verifierSkipped, ["reason": "the turn left no change to look at"])]
        var verifier = ThreadState.derive(from: events, id: "t").review.verifier
        #expect(verifier?.skipped == true && verifier?.reason == "the turn left no change to look at")
        let budget: JSONValue = ["ok": false, "reason": "stopped at the budget ($1)"]
        events += [event(4, .verifierStarted, [:]), event(5, .verifierEnded, budget)]
        verifier = ThreadState.derive(from: events, id: "t").review.verifier
        #expect(verifier?.skipped == false && verifier?.ok == false && verifier?.reason == "stopped at the budget ($1)")
    }

    private func report(_ events: [Event], criteria: [Criterion] = []) -> ReviewReport {
        ReviewReport(
            state: ThreadState.derive(from: events, id: "t"), title: "T", criteria: criteria, approval: "approved",
            goalProblem: nil, diff: .unavailable(reason: "x"))
    }

    private var finished: [Event] {
        [
            event(1, .turnStarted, ["resume": false]), event(2, .turnEnded, ["result": "succeeded"]),
            event(3, .verifierStarted, [:]), proofAdded(4, "seen.png", source: "verifier"),
            event(5, .verifierEnded, [
                "ok": true, "report": "c1: holds, the label reads Received\nc2: does not hold", "cost_usd": .double(0.0015),
                "duration_ms": 9000,
            ]),
        ]
    }

    @Test func reviewShowsTheVerifierAsANoteBesideTheCriteria() {
        let criteria = [
            Criterion(id: "c1", text: "label", proof: "screenshot: seen"), Criterion(id: "c2", text: "x", proof: "by hand"),
        ]
        let text = report(finished, criteria: criteria).render().joined(separator: "\n")
        #expect(text.contains("Verifier   advisory · finished · turn 1 · $0.0015 · 9s"), "\(text)")
        #expect(text.contains("proof/turn-1/seen.png  5 bytes"))
        #expect(text.contains("note: c1: holds, the label reads Received") && text.contains("note: c2: does not hold"))
        #expect(text.contains("not a pass"))
        #expect(text.contains("[c1] see screenshot") && text.contains("[c2] you check"), "a claim of success changes neither")
    }

    @Test func aFailedSkippedAndStaleVerifierEachSaySo() {
        let stopped: JSONValue = ["ok": false, "reason": "stopped"]
        var events = Array(finished.prefix(2)) + [event(3, .verifierStarted, [:]), event(4, .verifierEnded, stopped)]
        #expect(report(events).verifierLines().first == "Verifier   did not finish · turn 1: stopped")
        events = Array(finished.prefix(2)) + [event(3, .verifierSkipped, ["reason": "the turn left no change to look at"])]
        #expect(report(events).verifierLines() == ["Verifier   skipped: the turn left no change to look at"])
        events = finished + [
            event(6, .turnStarted, turn: 2, ["resume": true]), event(7, .turnEnded, turn: 2, ["result": "succeeded"]),
        ]
        #expect(report(events).verifierLines().first?.hasSuffix("(turn 1; the latest turn is 2)") == true)
        #expect(report(Array(finished.prefix(2))).verifierLines().isEmpty, "nothing when it has not run")
    }

    @Test func aLongNoteIsCutAtTwelveLinesAndEachLineIsBounded() {
        let long = (1...30).map { "line \($0) " + String(repeating: "x", count: 300) }.joined(separator: "\n")
        let said: JSONValue = ["ok": true, "report": .string(long)]
        let events = Array(finished.prefix(2)) + [event(3, .verifierStarted, [:]), event(4, .verifierEnded, said)]
        let lines = report(events).verifierLines()
        let notes = lines.filter { $0.hasPrefix("  note: ") }
        #expect(notes.count == ReviewReport.verifierNoteLines + 1)
        #expect(notes.allSatisfy { $0.count <= 8 + ReviewReport.verifierNoteWidth + 120 })
        #expect(notes.last?.contains("18 more line(s)") == true)
    }
}
