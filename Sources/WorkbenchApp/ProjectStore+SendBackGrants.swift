import Foundation
import WorkbenchCore

extension ProjectStore {
    /// Reads the thread's denied calls into the card. An answer for another project or thread is dropped.
    func loadSendBackGrants() async {
        guard let project, let thread = currentThread else { return }
        let mine = generation
        let candidates = (try? await actions.grantCandidates(project, thread)) ?? []
        guard mine == generation, thread == currentThread else { return }
        sendBackGrants = GrantRow.rows(candidates)
    }

    /// Records one decision through core, which decides whether it may stand. A decision is a log entry: it holds when the card is
    /// cancelled. `dangerous` is core's `--allow-dangerous`, passed only for an unsafe part's own confirm.
    func decide(_ row: GrantRow, _ scope: GrantScope, dangerous: Bool = false) async {
        guard let project, let thread = currentThread, grantsInFlight == 0 else { return }
        let mine = generation
        grantsInFlight += 1
        defer { grantsInFlight -= 1 }
        do {
            try await actions.grant(project, thread, row.number, scope, dangerous)
            await loadSendBackGrants()
        } catch {
            // The refusal belongs to the thread it was asked of: another project's row `1` is not this one's.
            guard mine == generation, thread == currentThread else { return }
            if let at = sendBackGrants.firstIndex(where: { $0.number == row.number }) {
                sendBackGrants[at].refusal = "\(error)"
            }
        }
    }
}
