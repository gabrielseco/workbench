import Foundation
import WorkbenchCore

extension ProjectStore {
    /// What is written in the guidance field of the thread on screen.
    var guidanceNote: String {
        get { currentThread.flatMap { guidanceNotes[$0] } ?? "" }
        set { if let thread = currentThread { guidanceNotes[thread] = newValue.isEmpty ? nil : newValue } }
    }

    /// The next turn with what is written for the agent. Core adds the failed check's output; the turn runs under the goal's budget.
    /// The text stays until a turn has begun, so a send the run refuses leaves it where it was.
    func sendGuidance() {
        let note = guidanceNote
        guard let project, let thread = currentThread, !starting else { return }
        guard !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            actionError = "Say what to change: a note is required."
            return
        }
        guard grantsInFlight == 0 else {
            actionError = "A decision is still being saved. Send once it is."
            return
        }
        actionError = nil
        startRun(project, thread, generation: generation, options: RunOptions(feedback: note))
    }

    /// Drops every written note and the grant rows: another project's are not this one's.
    func clearGuidance() {
        (guidanceNotes, sendBackGrants) = ([:], [])
    }
}
