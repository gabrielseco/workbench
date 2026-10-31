import Foundation
import WorkbenchCore

/// Ship runs on the click: core's preflight and the pull request text are read, then published as read. Never merges.
extension ProjectStore {
    /// Core refuses the publish when the branch moved since the preview, and nothing is pushed then.
    /// True when the branch was pushed and the pull request opened or updated.
    @discardableResult func ship() async -> Bool {
        guard let project, let thread = currentThread, !deciding, busy == nil else { return false }
        // Set before the first await, so a second click while this one is going starts nothing.
        deciding = true
        defer { deciding = false }
        actionError = nil
        notice = nil
        let mine = generation
        var shipped = false
        await working("Checking what Ship would do and describing the change…") {
            // The ship goes on when the person leaves the project, but what it says belongs to the project it was for.
            do {
                let preview = try await actions.shipPreview(project, thread)
                guard mine == generation else { return }
                nowWorking("Shipping: pushing the branch and opening the pull request…")
                let outcome = try await actions.ship(project, thread, preview)
                shipped = true
                if mine == generation {
                    notice = (["Shipped as PR #\(outcome.pr.number): \(outcome.pr.url)"] + [preview.note].compactMap { $0 })
                        .joined(separator: " ")
                    if let failure = outcome.refreshFailure { actionError = "\(failure)" }
                }
            } catch { if mine == generation { actionError = "\(error)" } }
            if mine == generation { await reload() }
        }
        return shipped
    }
}
