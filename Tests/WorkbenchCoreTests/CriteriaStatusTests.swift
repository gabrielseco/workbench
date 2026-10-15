import Foundation
import Testing

@testable import WorkbenchCore

private func crit(_ id: String, _ proof: String) -> Criterion {
    Criterion(id: id, text: "text of \(id)", proof: proof)
}

private func check(_ result: String, turn: Int = 1, exit: Int? = 0) -> Review.Check {
    Review.Check(turn: turn, result: result, exitCode: exit, durationMs: 2000, outputRef: nil)
}

private func eval(
    _ proofs: [String], command: String? = "npm run ci", check: Review.Check? = nil, lastTurn: Int = 1
) -> [CriterionStatus] {
    let criteria = proofs.enumerated().map { crit("c\($0.offset + 1)", $0.element) }
    return CriteriaStatus.evaluate(criteria: criteria, checkCommand: command, check: check, lastTurn: lastTurn)
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
        #expect(none[0].state == .manual && none[0].note == "the check has not run")
        let older = eval(["`npm run ci` passes"], check: check("passed", turn: 1), lastTurn: 2)
        #expect(older[0].state == .manual && older[0].note?.contains("turn 1") == true)
        let timedOut = eval(["`npm run ci` passes"], check: check("timed_out", exit: nil))
        #expect(timedOut[0].state == .manual && timedOut[0].note == "the check ended timed out")
    }

    @Test func noConfiguredCheckMeansEverythingIsForAPerson() {
        let out = eval(["`npm run ci` passes"], command: nil, check: check("passed"))
        #expect(out[0].state == .manual)
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
}
