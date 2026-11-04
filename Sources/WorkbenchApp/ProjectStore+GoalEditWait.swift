import Foundation

extension ProjectStore {
    /// Waits for the goal edits already made, for as long as `goalEditWait`; when they do not finish, says so on the thread and
    /// answers false, so the caller does nothing with a goal that may not be what the window shows.
    func goalEditsSettled(in session: ThreadSession) async -> Bool {
        guard let edits = session.goalEdits else { return true }
        if await Self.finished(edits, within: goalEditWait) { return true }
        session.actionError = "Your last edit to the goal did not finish saving, so nothing was started. Try again in a moment."
        return false
    }

    fileprivate static func finished(_ task: Task<Void, Never>, within wait: Duration) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = Once(continuation)
            Task { @MainActor in
                await task.value
                once.resume(true)
            }
            Task { @MainActor in
                try? await Task.sleep(for: wait)
                once.resume(false)
            }
        }
    }

    /// Answers a continuation once, whichever of two racers gets there first.
    @MainActor private final class Once {
        private var continuation: CheckedContinuation<Bool, Never>?
        init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }
        func resume(_ value: Bool) {
            continuation?.resume(returning: value)
            continuation = nil
        }
    }
}
