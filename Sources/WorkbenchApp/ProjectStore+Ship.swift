import Foundation
import WorkbenchCore

/// Ship: what core would push and open is fetched and shown first, and only what was shown is published. Never merges.
extension ProjectStore {
    func prepareShip() async {
        guard let project, let thread = currentThread, !deciding else { return }
        actionError = nil
        notice = nil
        let mine = generation
        await working("Checking what Ship would do and describing the change…") {
            do {
                let preview = try await actions.shipPreview(project, thread)
                if mine == generation { pendingShip = preview }
            } catch { if mine == generation { actionError = "\(error)" } }
        }
    }

    /// Publishes what was shown: core refuses it when the branch moved since, and nothing is pushed then.
    func confirmShip() async {
        guard let project, let thread = currentThread, let preview = pendingShip, !deciding else { return }
        deciding = true
        defer { deciding = false }
        pendingShip = nil
        await working("Shipping: pushing the branch and opening the pull request…") {
            do {
                let outcome = try await actions.ship(project, thread, preview)
                notice = "Shipped as PR #\(outcome.pr.number): \(outcome.pr.url)"
                if let failure = outcome.refreshFailure { actionError = "\(failure)" }
            } catch { actionError = "\(error)" }
            await reload()
        }
    }

    func cancelShip() { pendingShip = nil }
}
