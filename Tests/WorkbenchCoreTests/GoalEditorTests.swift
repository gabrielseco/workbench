import Foundation
import Testing

@testable import WorkbenchCore

/// A goal with a comment, a section the editor does not know, wrapped lines and a gap in the ids.
private let sample = """
    ---
    id: g-2026-10-30-edit
    title: Edit a goal  # keep this
    status: draft
    base: main
    budget_usd: 5.00
    turn_timeout_min: 30
    # a note about the model
    model: opus
    ---

    ## Request

    Do the thing,
    in two lines.

    ## Criteria

    - [c1] The first criterion
      wraps onto a second line.
      - proof: test: Suite/first
    - [c3] The third criterion.
      - proof: cat third

    ## Notes

    Kept exactly as written.

    ## Out of scope

    - Everything else.
    """

private func parsed(_ text: String = sample) throws -> GoalFile { try GoalFile.parse(text) }

@Suite struct GoalEditorTests {
    @Test func everyFixtureGoalReadsBackToTheSameBytesWhenNothingIsChanged() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/app")
        let goals = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.lastPathComponent == "goal.md" } ?? []
        for url in goals {
            guard let file = try? parsed(String(contentsOf: url, encoding: .utf8)) else { continue }
            // Setting the title to itself is an edit that changes nothing.
            let same = try GoalEditor.apply(.setTitle(file.goal.title), to: file)
            #expect(same.text == file.text, "\(url.path)")
        }
    }

    @Test func theTitleEditKeepsItsCommentAndEverythingElse() throws {
        let edited = try GoalEditor.apply(.setTitle("A new title"), to: parsed())
        #expect(edited.goal.title == "A new title")
        #expect(edited.text.contains("title: A new title  # keep this"))
        #expect(edited.text.contains("# a note about the model"))
        #expect(edited.goal.contentHash == (try parsed()).goal.contentHash, "the title is not bound by the approval")
    }

    @Test func theRequestIsReplacedAndOtherSectionsSurvive() throws {
        let edited = try GoalEditor.apply(.setRequest("One line now."), to: parsed())
        #expect(edited.goal.request == "One line now.")
        #expect(edited.text.contains("## Notes\n\nKept exactly as written."))
        #expect(edited.goal.criteria == (try parsed()).goal.criteria)
    }

    @Test func aRequestThatWouldStartASectionIsRefused() throws {
        #expect(throws: GoalEditError.self) { try GoalEditor.apply(.setRequest("Fine\n## Criteria\n- [c9] x"), to: parsed()) }
        #expect(throws: GoalEditError.self) { try GoalEditor.apply(.setRequest("  \n "), to: parsed()) }
    }

    @Test func aNewCriterionTakesTheNextFreeNumberAndLeavesTheOthersAlone() throws {
        let edited = try GoalEditor.apply(.addCriterion(text: "A fourth.", proof: "cat fourth"), to: parsed())
        #expect(edited.goal.criteria.map(\.id) == ["c1", "c3", "c4"])
        #expect(edited.text.contains("- [c1] The first criterion\n  wraps onto a second line.\n  - proof: test: Suite/first"))
    }

    @Test func removingACriterionDoesNotRenumberTheOthers() throws {
        let edited = try GoalEditor.apply(.removeCriterion(id: "c1"), to: parsed())
        #expect(edited.goal.criteria.map(\.id) == ["c3"])
        #expect(throws: GoalEditError.self) { try GoalEditor.apply(.removeCriterion(id: "c3"), to: edited) }
    }

    @Test func updatingACriterionChangesOnlyWhatWasGiven() throws {
        let edited = try GoalEditor.apply(.updateCriterion(id: "c3", text: nil, proof: "make check"), to: parsed())
        #expect(edited.goal.criteria.last == Criterion(id: "c3", text: "The third criterion.", proof: "make check"))
        #expect(edited.goal.criteria.first == (try parsed()).goal.criteria.first)
        #expect(throws: GoalEditError.self) {
            try GoalEditor.apply(.updateCriterion(id: "c9", text: "x", proof: nil), to: parsed())
        }
    }

    @Test func aMalformedScreenshotProofIsRefusedNotWritten() throws {
        #expect(throws: GoalEditError.self) {
            try GoalEditor.apply(.updateCriterion(id: "c1", text: nil, proof: "screenshot: a b!"), to: parsed())
        }
    }

    @Test func aCriterionIsOneLine() throws {
        #expect(throws: GoalEditError.self) { try GoalEditor.apply(.addCriterion(text: "a\n- [c9] b", proof: "x"), to: parsed()) }
        #expect(throws: GoalEditError.self) { try GoalEditor.apply(.addCriterion(text: "a", proof: ""), to: parsed()) }
    }

    @Test func aCriterionMovesToAPosition() throws {
        let edited = try GoalEditor.apply(.moveCriterion(id: "c3", to: 0), to: parsed())
        #expect(edited.goal.criteria.map(\.id) == ["c3", "c1"])
        #expect(throws: GoalEditError.self) { try GoalEditor.apply(.moveCriterion(id: "c3", to: 2), to: parsed()) }
    }

    @Test func outOfScopeIsReplacedAndCreatedWhenMissing() throws {
        let edited = try GoalEditor.apply(.setOutOfScope(["A", "B"]), to: parsed())
        #expect(edited.goal.outOfScope == ["A", "B"])
        let bare = sample.replacingOccurrences(of: "\n## Out of scope\n\n- Everything else.", with: "")
        let created = try GoalEditor.apply(.setOutOfScope(["Only this"]), to: parsed(bare))
        #expect(created.goal.outOfScope == ["Only this"])
    }
}

@Suite struct GoalSkipTests {
    @Test func skipIsReadAndTheEditorWritesAndClearsIt() throws {
        let edited = try GoalEditor.apply(.setSkip(["judge", "design"]), to: parsed())
        #expect(edited.goal.skip == ["judge", "design"] && edited.goal.skips("judge"))
        #expect(edited.text.contains("skip: judge, design"))
        let cleared = try GoalEditor.apply(.setSkip([]), to: edited)
        #expect(cleared.goal.skip.isEmpty && !cleared.text.contains("skip:"))
        #expect(cleared.text == sample)
    }

    @Test func aBadSkipListIsAGoalError() {
        for bad in ["skip: ", "skip: judge,,verifier", "skip: judge, judge", "skip: --x", "skip: a b"] {
            let text = sample.replacingOccurrences(of: "model: opus", with: "model: opus\n\(bad)")
            #expect(throws: GoalParseError.self, "\(bad)") { try GoalFile.parse(text) }
        }
    }

    @Test func changingSkipAfterApprovalMakesTheApprovalStale() throws {
        let approved = try parsed().approving()
        #expect(approved.goal.approval == .approved)
        let edited = try GoalEditor.apply(.setSkip(["judge"]), to: approved)
        #expect(edited.goal.approval == .stale)
        // The order the steps are listed in is not a change.
        let two = try GoalEditor.apply(.setSkip(["judge", "verifier"]), to: parsed()).approving()
        let swapped = try GoalEditor.apply(.setSkip(["verifier", "judge"]), to: two)
        #expect(swapped.goal.approval == .approved)
    }

    @Test func aGoalWithoutSkipKeepsTheHashItWasApprovedWith() {
        let plain = GoalHash.hash(base: "main", spend: .hardCap(5), turnTimeoutMin: 30, body: "b")
        #expect(plain == GoalHash.hash(base: "main", spend: .hardCap(5), turnTimeoutMin: 30, skip: [], body: "b"))
        #expect(plain != GoalHash.hash(base: "main", spend: .hardCap(5), turnTimeoutMin: 30, skip: ["judge"], body: "b"))
    }
}

@Suite(.processGate) struct GoalEditServiceTests {
    @Test func anEditIsWrittenAndRecordedAndStalesAnApprovedGoal() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        let edited = try await fx.service.editGoal(id: id, .setRequest("Changed my mind."))
        #expect(edited.goal.approval == .stale)
        let onDisk = try GoalFile.parse(String(contentsOf: fx.project.goalURL(id), encoding: .utf8))
        #expect(onDisk.goal.request == "Changed my mind." && onDisk.goal.approval == .stale)
        #expect(try fx.kinds(id).last == "goal.saved")
    }

    @Test func anEditIsRefusedAndWritesNothingWhenItWouldNotParse() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        let before = try String(contentsOf: fx.project.goalURL(id), encoding: .utf8)
        await #expect(throws: ThreadServiceError.self) { try await fx.service.editGoal(id: id, .removeCriterion(id: "c9")) }
        #expect(try String(contentsOf: fx.project.goalURL(id), encoding: .utf8) == before)
    }

    @Test func anEndedThreadCannotBeEdited() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        try await fx.service.abandon(id: id)
        await #expect(throws: ThreadServiceError.self) { try await fx.service.editGoal(id: id, .setTitle("x")) }
    }

    @Test func approveRefusesASkippedStepTheProjectDoesNotHave() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.service.newThread(name: "skip")
        let url = fx.project.goalURL(id)
        var text = try String(contentsOf: url, encoding: .utf8)
        for (placeholder, value) in [
            ("TODO(workbench): say what should change, in a few sentences.", "Do it."),
            ("TODO(workbench): something that can be checked.", "It is done."),
            ("TODO(workbench): how it will be shown (a test, a command, a screenshot).", "cat a.txt"),
            ("TODO(workbench): what must not change.", "Other files."),
        ] { text = text.replacingOccurrences(of: placeholder, with: value) }
        try text.write(to: url, atomically: true, encoding: .utf8)
        try await fx.service.editGoal(id: id, .setSkip(["nonesuch"]))
        await #expect(throws: ThreadServiceError.self) { try await fx.service.approve(id: id) }
        try await fx.service.editGoal(id: id, .setSkip(["judge", "verifier"]))
        _ = try await fx.service.approve(id: id)
    }
}

@Suite struct NextStepsSkipTests {
    private func events() -> [Event] {
        [
            Event(seq: 1, ts: "2026-10-30T10:00:00.000Z", turn: 1, kind: .turnStarted, data: [:]),
            Event(seq: 2, ts: "2026-10-30T10:01:00.000Z", turn: 1, kind: .turnEnded, data: ["result": "succeeded"]),
        ]
    }

    @Test func aSkippedJudgeAndAStageAreNotListed() throws {
        let config = try Config.parse(
            """
            check_command = "make test"
            [tools]
            available = ["Read"]
            allowed = ["Read"]
            [review]
            stages = ["pr-review", "design"]
            [review.stage.design]
            skill = "d.md"
            """)
        let all = NextSteps.derive(events: events(), files: [], config: config, id: "t")
        #expect(all.map(\.name) == ["judge", "design", "accept"])
        let skipped = NextSteps.derive(events: events(), files: [], config: config, skip: ["judge", "design"], id: "t")
        #expect(skipped.map(\.name) == ["accept"])
    }
}
