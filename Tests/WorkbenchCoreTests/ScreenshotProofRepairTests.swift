import Foundation
import Testing

@testable import WorkbenchCore

struct ScreenshotProofRepairTests {
    @Test func aPhraseBecomesOneToken() throws {
        let answer =
            #"{"title": "T", "request": "R", "criteria": [{"text": "Shows it.", "#
            + #""proof": "screenshot: Category edit screen, the (new) list"}], "out_of_scope": []}"#
        let proposal = try GoalDraft.proposal(fromAnswer: answer)
        #expect(proposal.body.criteria[0].proof == "screenshot: category-edit-screen, the-new-list")
    }

    @Test func usableAndOtherProofsAreUntouched() {
        #expect(ScreenshotProof.repaired("screenshot: a, b") == "screenshot: a, b")
        #expect(ScreenshotProof.repaired("test: FooTests/bar") == "test: FooTests/bar")
        #expect(ScreenshotProof.repaired("screenshot: ???") == "screenshot: ???")
    }
}
