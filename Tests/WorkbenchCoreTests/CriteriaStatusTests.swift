import Foundation
import Testing

@testable import WorkbenchCore

private func crit(_ id: String, _ proof: String) -> Criterion {
    Criterion(id: id, text: "text of \(id)", proof: proof)
}

private func check(
    _ result: String, turn: Int = 1, exit: Int? = 0, command: String? = "npm run ci"
) -> Review.Check {
    Review.Check(turn: turn, result: result, exitCode: exit, durationMs: 2000, outputRef: nil, command: command)
}

private func eval(_ proofs: [String], check: Review.Check? = nil, lastTurn: Int = 1) -> [CriterionStatus] {
    let criteria = proofs.enumerated().map { crit("c\($0.offset + 1)", $0.element) }
    return CriteriaStatus.evaluate(criteria: criteria, check: check, lastTurn: lastTurn)
}

@Suite struct CriteriaStatusTests {
    @Test func aProofThatIsTheCheckTakesItsResult() {
        let passed = eval(["`npm run ci` exits 0 on a clean checkout"], check: check("passed"))
        #expect(passed[0].state == .passed)
        let failed = eval(["`npm run ci` passes"], check: check("failed", exit: 2))
        #expect(failed[0].state == .failed)
        #expect(failed[0].note?.contains("exit 2") == true)
    }

    @Test func aProofWithFurtherStepsStaysForAPerson() {
        let proofs = [
            "`npm run ci` passes; after adding a badly formatted line to a file, `npm run ci` exits non-zero",
            "`npm run ci` passes and the workflow shows success on the PR",
            "`npm run format:check` exits 0; `package.json` / config diff",
        ]
        for status in eval(proofs, check: check("passed")) { #expect(status.state == .manual, "\(status)") }
    }

    @Test func noCheckOrAnOlderOneBacksNoVerdict() {
        let none = eval(["`npm run ci` passes"], check: nil)
        #expect(none[0].state == .manual && none[0].note == nil)
        let older = eval(["`npm run ci` passes"], check: check("passed", turn: 1), lastTurn: 2)
        #expect(older[0].state == .manual && older[0].note?.contains("turn 1") == true)
        let timedOut = eval(["`npm run ci` passes"], check: check("timed_out", exit: nil))
        #expect(timedOut[0].state == .manual && timedOut[0].note == "the check ended timed out")
    }

    @Test func theVerdictIsBoundToTheCommandThatRanNotTheConfigNow() {
        // The check that ran was `npm run lint`; a proof naming `npm run ci` was never proven by it.
        let other = eval(["`npm run ci` passes"], check: check("passed", command: "npm run lint"))
        #expect(other[0].state == .manual)
        let same = eval(["`npm run lint` passes"], check: check("passed", command: "npm run lint"))
        #expect(same[0].state == .passed)
        let synthetic = eval(["`npm run ci` passes"], check: check("interrupted", exit: nil, command: nil))
        #expect(synthetic[0].state == .manual)
    }

    @Test func aFreeTextProofHasNoCommandsAndTwoCommandsAreListed() {
        let out = eval(["unit test with injected clock", "`npm test` and `npx tsc --noEmit` pass"])
        #expect(out[0].commands.isEmpty)
        #expect(out[1].commands == ["npm test", "npx tsc --noEmit"])
    }

    @Test func summaryCountsAndSaysWhenNoCheckRan() {
        let mixed = eval(["`npm run ci` passes", "see the diff"], check: check("passed"))
        #expect(CriteriaStatus.summary(mixed, check: check("passed")) == "Criteria: 1 passed · 0 failed · 1 for you to check")
        let none = eval(["see the diff"])
        #expect(CriteriaStatus.summary(none, check: nil).hasSuffix("(check did not run)"))
    }

    @Test func renderListsCommandsUnderAManualRow() {
        let lines = CriteriaStatus.render(eval(["`npm test` passes; read the diff"]))
        #expect(lines == ["  [c1] you check", "         run: npm test"])
    }

    @Test func markdownTableEscapesPipesAndCarriesNoCheckOutput() {
        let statuses = eval(["`npm run ci` passes", "`grep a | wc -l` prints 3"], check: check("passed"))
        let table = CriteriaStatus.markdown(statuses) { $0 }
        #expect(table.contains("| c1 | ✔ passed |"))
        #expect(table.contains("`grep a \\| wc -l`"))
    }

    // MARK: Proofs that name tests

    private func ran(
        passed: [String] = [], failed: [String] = [], truncated: Bool = false, turn: Int = 1, result: String = "passed"
    ) -> Review.Check {
        var c = check(result, turn: turn)
        c.tests = CheckTests(passed: passed, failed: failed, truncated: truncated)
        return c
    }

    @Test func aNamedTestThatPassedInTheLatestTurnIsPassed() {
        let status = eval(["test: Suite/everythingOrder()"], check: ran(passed: ["everythingOrder()"]))
        #expect(status[0].state == .passed)
        #expect(status[0].note == "named test ran in the check, turn 1")
    }

    @Test func aNamedTestThatDidNotAppearStaysForAPerson() {
        let status = eval(["test: Suite/missing"], check: ran(passed: ["other()"]))
        #expect(status[0].state == .manual)
        #expect(status[0].note?.contains("did not appear") == true)
    }

    @Test func aNamedTestThatFailedIsFailed() {
        let status = eval(["test: Suite/broken"], check: ran(failed: ["broken()"], result: "failed"))
        #expect(status[0].state == .failed)
    }

    @Test func aPrefixPassesOnlyIfEveryMatchPassed() {
        let both = eval(["test: Suite/order*"], check: ran(passed: ["orderA()", "orderB()"]))
        #expect(both[0].state == .passed)
        let oneFailing = eval(["test: Suite/order"], check: ran(passed: ["orderA()"], failed: ["orderB()"]))
        #expect(oneFailing[0].state == .failed)
    }

    @Test func aNameThatCannotBeReadLeavesTheWholeProofToAPerson() {
        let status = eval(["test: Suite/a, Suite/not-a-name!"], check: ran(passed: ["a()"]))
        #expect(status[0].state == .manual)
        #expect(eval(["test: Suite/échec"], check: ran(passed: ["échec()"]))[0].state == .passed)
        #expect(eval(["test: Suite/a, Suite/échec"], check: ran(passed: ["a()"]))[0].state == .manual)
    }

    @Test func aNamedTestRowReachesThePullRequestTableAsACheckRun() {
        let rows = CriteriaStatus.markdown(
            eval(["test: a"], check: ran(passed: ["a()"])), oneLine: { $0 })
        #expect(rows.contains("✔ passed | Workbench's check run (named test ran in the check, turn 1)"))
    }

    @Test func aSeenFailureHoldsEvenWhenAnotherNameIsAbsent() {
        let status = eval(["test: broken, missing"], check: ran(failed: ["broken()"], result: "failed"))
        #expect(status[0].state == .failed)
    }

    @Test func severalNamesAllNeedToHavePassed() {
        let status = eval(["test: a, b"], check: ran(passed: ["a()"]))
        #expect(status[0].state == .manual)
        #expect(eval(["test: a, b"], check: ran(passed: ["a()", "b()"]))[0].state == .passed)
    }

    @Test func aCheckFromAnEarlierTurnOrNoCheckGivesNoVerdict() {
        let old = eval(["test: a"], check: ran(passed: ["a()"], turn: 1), lastTurn: 2)
        #expect(old[0].state == .manual)
        #expect(old[0].note?.contains("not the latest turn 2") == true)
        #expect(eval(["test: a"], check: nil)[0].state == .manual)
    }

    @Test func aCheckThatDidNotFinishOrListedNoTestsGivesNoVerdict() {
        #expect(eval(["test: a"], check: ran(passed: ["a()"], result: "timed_out"))[0].state == .manual)
        #expect(eval(["test: a"], check: check("passed"))[0].state == .manual, "format the parser does not know")
        #expect(eval(["test: a"], check: ran(passed: ["a()"], truncated: true))[0].state == .manual)
    }

    @Test func proseNamingOnlyRecordedTestsStillCountsAsTheFallback() {
        let c = ran(passed: ["everythingOrderIsKept()"])
        #expect(eval(["`everythingOrderIsKept` passes"], check: c)[0].state == .passed)
        #expect(eval(["`everythingOrderIsKept` passes and the doc says so"], check: c)[0].state == .manual)
        #expect(eval(["`notRecorded` passes"], check: c)[0].state == .manual)
    }

    @Test func aProofThatIsTheCheckKeepsItsOldBehaviourWhenTestsAreRecorded() {
        var c = ran(passed: ["a()"])
        c.command = "npm run ci"
        #expect(eval(["`npm run ci` passes"], check: c)[0].state == .passed)
    }
}
