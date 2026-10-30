import Foundation
import WorkbenchCore

extension ProjectStore {
    /// The next turn with a note for the agent, and an optional dollar cap for that one turn. Core adds the failed check's output.
    func sendBack() {
        let (note, budget) = (sendBackNote, sendBackBudget)
        guard let project, let thread = currentThread, !starting else { return }
        var options = RunOptions(feedback: note)
        if !budget.trimmingCharacters(in: .whitespaces).isEmpty {
            let text = budget.trimmingCharacters(in: .whitespaces)
            guard text.range(of: #"^[0-9]+(\.[0-9]+)?$"#, options: .regularExpression) != nil,
                let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), value > 0
            else {
                actionError = "The budget must be a positive number of dollars, got '\(text)'."
                return
            }
            options.budgetOverride = value
        }
        guard !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            actionError = "Say what to change: a note is required."
            return
        }
        actionError = nil
        sendingBack = false
        startRun(project, thread, generation: generation, options: options)
    }

    /// Closes the card and drops what was written in it.
    func cancelSendBack() {
        (sendingBack, sendBackNote, sendBackBudget) = (false, "", "")
    }

    /// A send the run would not start: the card comes back with the text, and the error under it.
    func reopenSendBack() {
        if !sendBackNote.isEmpty { sendingBack = true }
    }
}
