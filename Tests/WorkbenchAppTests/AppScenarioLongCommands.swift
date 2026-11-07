import Foundation
import WorkbenchCore

extension AppScenario {
    /// `running` with refused Bash calls longer than a line: the feed wraps them instead of cutting them to one.
    @MainActor func buildLongCommands(in fixture: AppFixture) async throws {
        let id = "invoice-pagination"
        let long =
            "git add -A && git commit -q -m \"feat(invoices): paginate the contractor invoice list, fetch 50 rows a page, "
            + "keep the scroll position when a page loads and show the total count in the header\" && git push origin HEAD"
        try await fixture.addThread(id, approved: true, title: Self.title)
        try fixture.append(id, .turnStarted, turn: 1, data: ["session_id": "s1"])
        try fixture.activity(id, ["type": "permission_denied", "tool": "Bash", "input": .string(long)])
        try fixture.activity(id, ["type": "permission_denied", "tool": "Bash", "input": "git push origin main"])
    }
}
