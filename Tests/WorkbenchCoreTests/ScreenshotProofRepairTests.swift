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
        #expect(ScreenshotProof.repaired("screenshot: home screen, !!!") == "screenshot: home screen, !!!")
        #expect(ScreenshotProof.repaired("screenshot: Home Screen, home-screen") == "screenshot: Home Screen, home-screen")
        let many = (1...17).map { "shot \($0)" }.joined(separator: ", ")
        #expect(ScreenshotProof.repaired("screenshot: " + many) == "screenshot: " + many)
    }
}
