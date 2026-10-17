import Foundation
import Testing

@testable import WorkbenchCore

private let draftGoal = """
    ---
    id: g-2026-10-12-retry-backoff
    title: Add retry with backoff to the sync client
    status: draft               # draft | approved
    base: main                  # branch the worktree is cut from
    budget_usd: 5.00            # hard cap passed to the CLI
    turn_timeout_min: 30
    ---

    ## Request

    Add exponential retry with jitter to `SyncClient.fetch`, max 5 attempts.

    ## Criteria

    - [c1] `SyncClient.fetch` retries on 5xx and network errors, not on 4xx.
      - proof: test `SyncClientTests.retries*` pass
    - [c2] Delay grows exponentially with jitter and is capped at 30s.
      - proof: unit test with injected clock

    ## Out of scope

    - Changing the request timeout.
    - Retrying uploads.
    """

private func problems(in text: String) -> [GoalProblem] {
    do {
        _ = try GoalFile.parse(text)
        return []
    } catch let error as GoalParseError {
        return error.problems
    } catch {
        Issue.record("unexpected error \(error)")
        return []
    }
}

private func codes(_ text: String) -> [GoalProblem.Code] { problems(in: text).map(\.code) }

private let fixedDate = Date(timeIntervalSince1970: 1_791_835_800)  // any instant works

@Suite struct GoalFileParsingTests {
    @Test func parsesTheSpecExample() throws {
        let goal = try GoalFile.parse(draftGoal).goal
        #expect(goal.id == "g-2026-10-12-retry-backoff")
        #expect(goal.title == "Add retry with backoff to the sync client")
        #expect(goal.base == "main")
        #expect(goal.budgetUSD == 5)
        #expect(goal.turnTimeoutMin == 30)
        #expect(goal.declaredStatus == .draft)
        #expect(goal.request.hasPrefix("Add exponential retry"))
        #expect(goal.criteria.map(\.id) == ["c1", "c2"])
        #expect(goal.criteria[0].proof == "test `SyncClientTests.retries*` pass")
        #expect(goal.outOfScope == ["Changing the request timeout.", "Retrying uploads."])
        #expect(goal.approval == .draft)
        #expect(goal.status == .draft)
    }

    @Test func outOfScopeIsOptionalAndCriterionTextMayWrap() throws {
        let text = draftGoal.replacingOccurrences(of: "## Out of scope", with: "## Notes")
            .replacingOccurrences(
                of: "- [c2] Delay grows exponentially with jitter and is capped at 30s.\n  - proof:",
                with: "- [c2] Delay grows exponentially\n  with jitter and is capped at 30s.\n  - proof:")
        let goal = try GoalFile.parse(text).goal
        #expect(goal.outOfScope.isEmpty)
        #expect(goal.criteria[1].text == "Delay grows exponentially with jitter and is capped at 30s.")
    }

    @Test func hashInTitleIsNotAComment() throws {
        let text = draftGoal.replacingOccurrences(
            of: "title: Add retry with backoff to the sync client", with: "title: Fix #12 retry")
        #expect(try GoalFile.parse(text).goal.title == "Fix #12 retry")
    }

    @Test func crlfLineEndingsParse() throws {
        let text = draftGoal.replacingOccurrences(of: "\n", with: "\r\n")
        #expect(try GoalFile.parse(text).goal.criteria.count == 2)
    }
}

@Suite struct GoalApprovalTests {
    @Test func approvingBindsTheHashAndKeepsTheRestOfTheFile() throws {
        let draft = try GoalFile.parse(draftGoal)
        let approved = try draft.approving(at: fixedDate)

        #expect(approved.goal.approval == .approved)
        #expect(approved.goal.status == .approved)
        #expect(approved.goal.approvedHash == draft.goal.contentHash)
        #expect(approved.goal.approvedAt?.hasSuffix("Z") == true)
        // Body, comments and key order survive.
        #expect(approved.text.contains("status: approved  # draft | approved"))
        #expect(approved.text.contains("base: main  # branch the worktree is cut from"))
        #expect(approved.text.hasSuffix(String(draftGoal.split(separator: "---\n", maxSplits: 2).last!)))
        // And it round-trips: re-parsing the written text is still approved.
        #expect(try GoalFile.parse(approved.text).goal.approval == .approved)
    }

    @Test func approvingAnApprovedGoalChangesNothing() throws {
        let once = try GoalFile.parse(draftGoal).approving(at: fixedDate)
        let twice = try once.approving(at: fixedDate.addingTimeInterval(3600))
        #expect(twice.text == once.text)
    }

    @Test(arguments: [
        ("Add exponential retry", "Add linear retry"),
        ("max 5 attempts", "max 6 attempts"),
        ("injected clock", "a fake clock"),
        ("Retrying uploads.", "Retrying downloads."),
        ("- [c2]", "- [c3]"),
    ])
    func editingTheBodyAfterApprovalReturnsToDraft(from: String, to: String) throws {
        let approved = try GoalFile.parse(draftGoal).approving(at: fixedDate)
        let edited = approved.text.replacingOccurrences(of: from, with: to)
        #expect(edited != approved.text)

        let reparsed = try GoalFile.parse(edited).goal
        #expect(reparsed.declaredStatus == .approved)
        #expect(reparsed.approval == .stale)
        #expect(reparsed.status == .draft)
    }

    @Test(arguments: [
        ("base: main", "base: develop"),
        ("budget_usd: 5.00", "budget_usd: 50.00"),
        ("turn_timeout_min: 30", "turn_timeout_min: 60"),
    ])
    func editingAnExecutionFieldAfterApprovalReturnsToDraft(from: String, to: String) throws {
        let approved = try GoalFile.parse(draftGoal).approving(at: fixedDate)
        let edited = approved.text.replacingOccurrences(of: from, with: to)
        #expect(edited != approved.text)
        #expect(try GoalFile.parse(edited).goal.status == .draft)
    }

    @Test func editsThatDoNotChangeMeaningKeepApproval() throws {
        let approved = try GoalFile.parse(draftGoal).approving(at: fixedDate)
        var edited = approved.text
            .replacingOccurrences(of: "title: Add retry with backoff to the sync client", with: "title: A better title")
            .replacingOccurrences(of: "budget_usd: 5.00", with: "budget_usd: 5")
            .replacingOccurrences(of: "## Request\n", with: "## Request   \n")
        edited += "\n\n\n"
        edited = edited.replacingOccurrences(of: "\n", with: "\r\n")

        let reparsed = try GoalFile.parse(edited).goal
        #expect(reparsed.title == "A better title")
        #expect(reparsed.approval == .approved)
    }

    @Test func claimingApprovalWithoutAHashIsStale() throws {
        let text = draftGoal.replacingOccurrences(of: "status: draft", with: "status: approved")
        let goal = try GoalFile.parse(text).goal
        #expect(goal.approval == .stale)
        #expect(goal.status == .draft)
    }

    @Test func aWrongHashIsStale() throws {
        let approved = try GoalFile.parse(draftGoal).approving(at: fixedDate)
        let hash = try #require(approved.goal.approvedHash)
        let forged = approved.text.replacingOccurrences(of: hash, with: String(repeating: "0", count: 64))
        #expect(try GoalFile.parse(forged).goal.status == .draft)
    }
}

@Suite struct GoalValidationTests {
    @Test func notStartingWithFrontMatter() {
        #expect(codes("## Request\nhi") == [.missingFrontMatter])
        #expect(codes("") == [.missingFrontMatter])
    }

    @Test func unterminatedFrontMatter() {
        #expect(codes("---\nid: x\ntitle: y\n") == [.unterminatedFrontMatter])
    }

    @Test func missingRequiredKeysAreNamed() {
        let text = "---\nid: g1\n---\n\n## Request\nhi\n\n## Criteria\n- [c1] a\n  - proof: b\n"
        let found = problems(in: text)
        #expect(found.map(\.code) == [.missingKey, .missingKey, .missingKey, .missingKey])
        let named = found.map(\.message).joined()
        for key in ["title", "base", "budget_usd", "turn_timeout_min"] {
            #expect(named.contains("'\(key)'"))
        }
    }

    @Test func badValuesPointAtTheirLine() {
        let text = draftGoal
            .replacingOccurrences(of: "budget_usd: 5.00", with: "budget_usd: lots")
            .replacingOccurrences(of: "turn_timeout_min: 30", with: "turn_timeout_min: 0")
            .replacingOccurrences(of: "status: draft ", with: "status: maybe ")
        let found = problems(in: text)
        #expect(found.map(\.code) == [.invalidValue, .invalidValue, .invalidValue])
        #expect(found.map(\.line) == [4, 6, 7])
        #expect(found[0].message.contains("status"))
        #expect(found[1].message.contains("budget_usd"))
        #expect(found[2].message.contains("turn_timeout_min"))
    }

    @Test(arguments: ["../escape", "a/b", "-rf", "has space", ".hidden", ""])
    func idMustBeSafeAsADirectoryName(_ id: String) {
        let text = draftGoal.replacingOccurrences(of: "id: g-2026-10-12-retry-backoff", with: "id: \"\(id)\"")
        #expect(codes(text).contains(.invalidValue))
    }

    @Test(arguments: ["--upload-pack=x", "a..b", "has space", "-main"])
    func baseMustBeASafeBranchName(_ base: String) {
        let text = draftGoal.replacingOccurrences(of: "base: main ", with: "base: \"\(base)\" ")
        #expect(codes(text).contains(.invalidValue))
    }

    @Test func unknownAndDuplicateKeys() {
        let text = draftGoal.replacingOccurrences(
            of: "turn_timeout_min: 30", with: "turn_timeout_min: 30\nbudjet_usd: 9\nbase: dev")
        #expect(Set(codes(text)) == [.unknownKey, .duplicateKey])
    }

    @Test func malformedFrontMatterLine() {
        let text = draftGoal.replacingOccurrences(of: "turn_timeout_min: 30", with: "turn_timeout_min 30")
        #expect(codes(text).contains(.malformedFrontMatterLine))
    }

    @Test func missingAndEmptySections() {
        let noRequest = draftGoal.replacingOccurrences(of: "## Request", with: "## Ask")
        #expect(codes(noRequest) == [.missingSection])

        let emptyRequest = draftGoal.replacingOccurrences(
            of: "Add exponential retry with jitter to `SyncClient.fetch`, max 5 attempts.", with: "")
        #expect(codes(emptyRequest) == [.emptySection])

        let noCriteria = draftGoal.replacingOccurrences(of: "## Criteria", with: "## Checks")
        #expect(codes(noCriteria) == [.missingSection])
    }

    @Test func criterionProblems() {
        let noProof = draftGoal.replacingOccurrences(of: "  - proof: unit test with injected clock\n", with: "")
        #expect(codes(noProof) == [.criterionWithoutProof])

        let emptyProof = draftGoal.replacingOccurrences(of: "proof: unit test with injected clock", with: "proof:")
        #expect(codes(emptyProof) == [.criterionWithoutProof])

        let duplicate = draftGoal.replacingOccurrences(of: "- [c2]", with: "- [c1]")
        #expect(codes(duplicate) == [.duplicateCriterionID])

        let noID = draftGoal.replacingOccurrences(of: "- [c2] Delay", with: "- Delay")
        #expect(codes(noID).contains(.malformedCriterion))

        let badID = draftGoal.replacingOccurrences(of: "- [c2]", with: "- [two]")
        #expect(codes(badID).contains(.malformedCriterion))
    }

    @Test func duplicateSection() {
        #expect(codes(draftGoal + "\n\n## Request\n\nagain\n") == [.duplicateSection])
    }

    @Test func aByHandProofIsParsedAndKeptInTheFileText() throws {
        let text = draftGoal.replacingOccurrences(
            of: "  - proof: unit test with injected clock", with: "  - proof (by hand): look at the output\n    and compare")
        let file = try GoalFile.parse(text)
        #expect(file.goal.criteria.map(\.byHand) == [false, true])
        #expect(file.goal.criteria[1].proof == "look at the output and compare")
        #expect(file.text.contains("- proof (by hand):"))
    }

    @Test func aMalformedProofMarkerIsAGoalError() {
        for marker in ["proof (by hands):", "proof (manual):", "proof (by hand)", "proof ():"] {
            let text = draftGoal.replacingOccurrences(of: "- proof: unit test with injected clock", with: "- \(marker) x")
            #expect(codes(text).contains(.malformedProofMarker), "\(marker)")
        }
        let empty = draftGoal.replacingOccurrences(
            of: "- proof: unit test with injected clock", with: "- proof (by hand):")
        #expect(codes(empty) == [.criterionWithoutProof])
    }

    @Test func allProblemsAreReportedTogetherInFileOrder() {
        let text = draftGoal
            .replacingOccurrences(of: "budget_usd: 5.00", with: "budget_usd: -1")
            .replacingOccurrences(of: "  - proof: unit test with injected clock\n", with: "")
        let found = problems(in: text)
        #expect(found.count == 2)
        #expect(found[0].code == .invalidValue)
        #expect(found[1].code == .criterionWithoutProof)
        #expect(found[0].line! < found[1].line!)
    }
}
