import Foundation
import Testing
import WorkbenchCore

@testable import WorkbenchApp

@MainActor @Suite struct ToolbarLabelTests {
    @Test func theProjectPillIsNamedForWhatItDoes() {
        #expect(ToolbarBar.projectButtonLabel(nil) == "Choose project")
        let named = ToolbarBar.projectButtonLabel(Project(root: URL(fileURLWithPath: "/Users/you/code/remote-flows")))
        #expect(named == "Choose project, now remote-flows")
    }

    @Test func theVerifyScriptRefusesEveryLabelThatOpensAPanel() throws {
        // The refusal in scripts/verify-app.sh matches the start of a label; every such label has to match it.
        let refused = try #require(
            try String(
                contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                    .deletingLastPathComponent().appendingPathComponent("scripts/verify-app.sh"), encoding: .utf8
            ).split(separator: "\n").first { $0.hasPrefix("REFUSED=") })
        let pattern = String(refused.dropFirst("REFUSED='".count).dropLast())
        for label in [
            ToolbarBar.projectButtonLabel(nil), ToolbarBar.projectButtonLabel(Project(root: URL(fileURLWithPath: "/x/project"))),
            "Choose project…", "Event log 4", "Open the event log",
        ] {
            #expect(label.range(of: pattern, options: .regularExpression) != nil, "\(label) would not be refused")
        }
        #expect("Doctor, Not run".range(of: pattern, options: .regularExpression) == nil)
    }
}
