import Foundation
import WorkbenchCore

extension ProjectStore {
    /// The next turn with a note for the agent. Core adds the failed check's output; the turn runs under the goal's budget.
    func sendBack() {
        let note = sendBackNote
        guard let project, let thread = currentThread, !starting else { return }
        guard !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            actionError = "Say what to change: a note is required."
            return
        }
        guard grantsInFlight == 0 else {
            actionError = "A decision is still being saved. Send back once it is."
            return
        }
        actionError = nil
        sendingBack = false
        startRun(project, thread, generation: generation, options: RunOptions(feedback: note))
    }

    /// Closes the card and drops what was written in it.
    func cancelSendBack() {
        (sendingBack, sendBackNote, sendBackGrants) = (false, "", [])
    }

    /// A send the run would not start: the card comes back with the text, and the error under it.
    func reopenSendBack() {
        if !sendBackNote.isEmpty { sendingBack = true }
    }
}
