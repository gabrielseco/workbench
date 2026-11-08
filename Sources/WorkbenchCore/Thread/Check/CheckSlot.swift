import Foundation

/// A check that was not started because `max_concurrent_checks` others were running. Recorded as a failed check that says so.
struct CheckRefused: Error { var reason: String }

/// The gate in front of a check: at most `max` threads of a project run their check at once. A check over it is refused with the
/// running ones named, never queued and never slowed. The count and the claim happen under the project's admission lock.
struct CheckSlot {
    let project: Project
    let threadID: String
    let max: Int

    enum Outcome: Equatable {
        case granted
        case refused(String)
    }

    /// Holds the admission lock until `release()`.
    final class Claim {
        let outcome: Outcome
        private var descriptor: Int32?

        init(outcome: Outcome, descriptor: Int32) {
            self.outcome = outcome
            self.descriptor = descriptor
        }

        func release() {
            if let descriptor { close(descriptor) }
            descriptor = nil
        }

        deinit { release() }
    }

    func claim() throws -> Claim {
        let descriptor = try ThreadStore.admit(project.threadsDirectory)
        let busy = ThreadStore(project: project).runningChecks(excluding: threadID)
        return Claim(
            outcome: busy.count >= max ? .refused(Self.message(running: busy, max: max)) : .granted, descriptor: descriptor)
    }

    static func message(running: [String], max: Int) -> String {
        "refused: \(running.count) of \(max) allowed checks are already running (\(running.joined(separator: ", "))); "
            + "`max_concurrent_checks` is \(max). Run this thread again when one has finished."
    }
}
