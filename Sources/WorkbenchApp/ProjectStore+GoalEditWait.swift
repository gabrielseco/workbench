import Foundation

extension ProjectStore {
    /// Waits for the goal edits already made, for as long as `goalEditWait`; when they do not finish, says so on the thread and
    /// answers false, so the caller does nothing with a goal that may not be what the window shows. It polls a count rather than
    /// awaiting the edit's task, so a stuck edit leaves nothing suspended behind each timeout.
    func goalEditsSettled(in session: ThreadSession) async -> Bool {
        let deadline = ContinuousClock.now + goalEditWait
        while session.goalEditsInFlight > 0 {
            if ContinuousClock.now >= deadline {
                session.actionError =
                    "Your last edit to the goal did not finish saving, so nothing was started. Try again in a moment."
                return false
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }
}
