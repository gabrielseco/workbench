import Foundation
import Testing

@testable import WorkbenchCore

private func crit(_ proof: String) -> Criterion { Criterion(id: "c1", text: "shows it", proof: proof) }

private func verifier(turn: Int = 1, ok: Bool = true, files: [String]) -> Review.Verifier {
    Review.Verifier(
        turn: turn, ok: ok, reason: ok ? nil : "timed out", skipped: false, costUSD: nil, durationMs: 1000, report: "",
        proof: files.map { ProofFile(name: $0, path: "proof/turn-\(turn)/\($0)", sha256: "ab", bytes: 3) }, open: false)
}

private func status(_ proof: String, verifier: Review.Verifier?, lastTurn: Int = 1) -> CriterionStatus {
    CriteriaStatus.evaluate(criteria: [crit(proof)], check: nil, lastTurn: lastTurn, verifier: verifier)[0]
}

@Suite struct ScreenshotProofParsingTests {
    @Test func aScreenshotProofNamesOneFile() {
        #expect(ScreenshotProof.name(in: "screenshot: bot-findings") == "bot-findings")
        #expect(ScreenshotProof.name(in: "  Screenshot:   home.dark ") == "home.dark")
        #expect(ScreenshotProof.fileName(for: "home") == "home.png")
    }

    @Test func otherProofsAreNotScreenshotProofs() {
        #expect(ScreenshotProof.name(in: "screenshot of Settings") == nil)
        #expect(ScreenshotProof.name(in: "`swift test` passes") == nil)
        #expect(!ScreenshotProof.isMalformed("screenshot of Settings"))
    }

    @Test func aNameThatCouldEscapeTheProofDirectoryIsMalformed() {
        for bad in ["screenshot: ../x", "screenshot: a/b", "screenshot: ", "screenshot: two words", "screenshot: -x",
            "screenshot: \(String(repeating: "a", count: 65))"] {
            #expect(ScreenshotProof.name(in: bad) == nil, "\(bad)")
            #expect(ScreenshotProof.isMalformed(bad), "\(bad)")
        }
    }

    @Test func aGoalWithAMalformedScreenshotProofIsRefusedWithTheLine() throws {
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
              - proof: screenshot: ../etc/passwd

            ## Out of scope

            - Nothing.
            """
        do {
            _ = try GoalFile.parse(text)
            Issue.record("expected a parse error")
        } catch let error as GoalParseError {
            #expect(error.problems.contains { $0.code == .malformedScreenshotProof })
            #expect(error.description.contains("screenshot: <name>"))
        }
    }
}

@Suite struct ScreenshotProofStatusTests {
    @Test func theFileThereIsEvidenceForAPersonNotAPass() {
        let s = status("screenshot: home", verifier: verifier(files: ["home.png", "other.png"]))
        #expect(s.state == .evidence)
        #expect(s.file == "proof/turn-1/home.png")
        #expect(s.label == "see screenshot")
    }

    @Test func noVerifierMeansMissing() {
        let s = status("screenshot: home", verifier: nil)
        #expect(s.state == .missing)
        #expect(s.note == "no verifier has run, so home.png was not produced")
    }

    @Test func aFileThatIsNotThereIsMissingEvenWhenTheVerifierFinished() {
        let s = status("screenshot: home", verifier: verifier(files: ["other.png"]))
        #expect(s.state == .missing)
        #expect(s.note?.contains("home.png") == true)
    }

    @Test func aVerifierRunFromAnEarlierTurnSaysNothingAboutTheLatestWork() {
        let s = status("screenshot: home", verifier: verifier(turn: 1, files: ["home.png"]), lastTurn: 2)
        #expect(s.state == .missing)
        #expect(s.note?.contains("not the latest turn 2") == true)
    }

    @Test func aVerifierThatDidNotFinishButLeftTheFileStillShowsIt() {
        let s = status("screenshot: home", verifier: verifier(ok: false, files: ["home.png"]))
        #expect(s.state == .evidence)
        #expect(s.note?.contains("verifier did not finish") == true)
    }

    @Test func aSubdirectoryFileDoesNotSatisfyAName() {
        #expect(status("screenshot: home", verifier: verifier(files: ["flows/home.png"])).state == .missing)
    }

    @Test func theSummaryCountsThemAndKeepsTheOldWordingWhenThereAreNone() {
        let criteria = [crit("screenshot: a"), Criterion(id: "c2", text: "t", proof: "read it"), crit("screenshot: b")]
        let statuses = CriteriaStatus.evaluate(
            criteria: criteria, check: nil, lastTurn: 1, verifier: verifier(files: ["a.png"]))
        #expect(
            CriteriaStatus.summary(statuses, check: nil)
                == "Criteria: 0 passed · 0 failed · 1 for you to check · 1 with a screenshot · 1 missing (check did not run)")
        let plain = CriteriaStatus.evaluate(criteria: [criteria[1]], check: nil, lastTurn: 1)
        #expect(
            CriteriaStatus.summary(plain, check: nil)
                == "Criteria: 0 passed · 0 failed · 1 for you to check (check did not run)")
    }

    @Test func theMarkdownTablePointsAtTheScreenshotAndSaysWhenItIsMissing() {
        let criteria = [crit("screenshot: a"), Criterion(id: "c2", text: "t", proof: "screenshot: b")]
        let statuses = CriteriaStatus.evaluate(criteria: criteria, check: nil, lastTurn: 1, verifier: verifier(files: ["a.png"]))
        let table = CriteriaStatus.markdown(statuses) { $0 }
        #expect(table.contains("| c1 | see screenshot | look at the screenshot"))
        #expect(table.contains("| c2 | ✘ missing | no screenshot"))
    }
}

@Suite struct ScreenshotProofFileTests {
    @Test func aRecordedFileThatIsGoneOrChangedIsMissingNotEvidence() throws {
        let thread = Scratch.url("thread")
        let dir = thread.appendingPathComponent("proof/turn-1")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: thread) }
        let file = dir.appendingPathComponent("home.png")
        try Data("abc".utf8).write(to: file)
        let v = verifier(files: ["home.png"])  // recorded as 3 bytes

        func report() -> ReviewReport {
            ReviewReport(
                state: ThreadState.derive(from: [], id: "t"), title: "T", criteria: [crit("screenshot: home")],
                approval: "approved", goalProblem: nil, diff: .unavailable(reason: "x"), threadDirectory: thread)
        }
        func eval(_ available: (ProofFile) -> Bool) -> CriterionStatus {
            CriteriaStatus.evaluate(
                criteria: [crit("screenshot: home")], check: nil, lastTurn: 1, verifier: v, proofAvailable: available)[0]
        }
        #expect(eval { $0.isAvailable(in: thread) }.state == .evidence)

        try Data("abcd".utf8).write(to: file)  // changed since it was recorded
        let changed = eval { $0.isAvailable(in: thread) }
        #expect(changed.state == .missing)
        #expect(changed.note?.contains("gone, unreadable or changed") == true)

        try FileManager.default.removeItem(at: file)
        #expect(eval { $0.isAvailable(in: thread) }.state == .missing)

        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        #expect(eval { $0.isAvailable(in: thread) }.state == .missing, "a link is not the recorded file")
        _ = report()
    }
}

@Suite struct ScreenshotProofFromTheLogTests {
    private func event(_ seq: Int, _ kind: EventKind, _ data: JSONValue) -> Event {
        Event(seq: seq, ts: "t", turn: 1, kind: kind, data: data)
    }

    private let turn = [
        Event(seq: 1, ts: "t", turn: 1, kind: .turnStarted, data: ["session_id": "s"]),
        Event(seq: 2, ts: "t", turn: 1, kind: .turnEnded, data: ["result": "succeeded"]),
    ]

    private func statuses(_ events: [Event]) -> [CriterionStatus] {
        let state = ThreadState.derive(from: events, id: "g-1")
        return CriteriaStatus.evaluate(
            criteria: [crit("screenshot: home"), crit("screenshot: nope")], check: nil, lastTurn: state.lastTurn,
            verifier: state.review.verifier)
    }

    @Test func theLogsVerifierEventsDecideWhetherTheScreenshotIsThere() {
        let shot: JSONValue = [
            "name": "home.png", "path": "proof/turn-1/home.png", "sha256": "ab", "bytes": 3, "source": "verifier",
        ]
        let found = statuses(
            turn + [event(3, .verifierStarted, [:]), event(4, .proofAdded, shot), event(5, .verifierEnded, ["ok": true])])
        #expect(found.map(\.state) == [.evidence, .missing])
        #expect(found[0].file == "proof/turn-1/home.png")
    }

    @Test func anOldLogsVerifyStepIsNotProof() {
        let shot: JSONValue = ["name": "home.png", "path": "proof/turn-1/home.png", "sha256": "ab", "bytes": 3]
        let old = statuses(
            turn + [
                event(3, .verifyStarted, ["command": "scripts/verify.sh"]), event(4, .proofAdded, shot),
                event(5, .verifyEnded, ["result": "passed", "exit_code": 0, "duration_ms": 10]),
            ])
        #expect(old.map(\.state) == [.missing, .missing])
        #expect(old[0].note?.contains("no verifier has run") == true)
    }
}

@Suite struct ScreenshotProofConfigTests {
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

    @Test func aScreenshotProofWithTheVerifierOffIsWarned() throws {
        let config = try Config.parse("[verifier]\nenabled = false\n[tools]\navailable = [\"Read\"]\n")
        let warnings = ProofCommands.warnings(goal: try goal("screenshot: home"), config: config)
        #expect(warnings.count == 1)
        #expect(warnings[0].line.contains("no verifier skill"))
        #expect(warnings[0].line.contains("home.png"))
    }

    @Test func theDefaultVerifierIsNotWarnedAbout() throws {
        let config = try Config.parse("[tools]\navailable = [\"Read\"]\n")
        #expect(ProofCommands.warnings(goal: try goal("screenshot: home"), config: config).isEmpty)
    }

    @Test func theDefaultVerifierWithNoSkillAtTheBaseIsWarned() throws {
        let config = try Config.parse("[tools]\navailable = [\"Read\"]\n")
        let warnings = ProofCommands.warnings(goal: try goal("screenshot: home"), config: config, verifierSkillAvailable: false)
        #expect(warnings.count == 1 && warnings[0].line.contains("no verifier skill"))
    }
}
