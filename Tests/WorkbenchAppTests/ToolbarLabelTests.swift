import Foundation
import Testing
import WorkbenchCore

@testable import WorkbenchApp

@MainActor @Suite struct ToolbarLabelTests {
    @Test func theProjectPillIsNamedForWhatItDoes() {
        #expect(ToolbarBar.projectButtonLabel(nil) == "Projects")
        let named = ToolbarBar.projectButtonLabel(Project(root: URL(fileURLWithPath: "/Users/you/code/remote-flows")))
        #expect(named == "Projects, now remote-flows")
    }

    @Test func theVerifyScriptRefusesEveryLabelThatOpensAPanel() throws {
        // The refusal in scripts/verify-app.sh matches the start of a label; every such label has to match it.
        let refused = try #require(
            try String(
                contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                    .deletingLastPathComponent().appendingPathComponent("scripts/verify-app.sh"), encoding: .utf8
            ).split(separator: "\n").first { $0.hasPrefix("REFUSED=") })
        let pattern = String(refused.dropFirst("REFUSED='".count).dropLast())
        for label in ["Choose project…", "Choose folder…", "Event log 4", "Open the event log"] {
            #expect(label.range(of: pattern, options: .regularExpression) != nil, "\(label) would not be refused")
        }
        // The pill opens the project card, which a scenario has to be able to show.
        for label in [
            "Doctor, Not run", ToolbarBar.projectButtonLabel(nil),
            ToolbarBar.projectButtonLabel(Project(root: URL(fileURLWithPath: "/x/project"))),
        ] {
            #expect(label.range(of: pattern, options: .regularExpression) == nil, "\(label) would be refused")
        }
    }
}
