import Foundation
import Observation
import WorkbenchCore

/// What the window is doing for one thread: the words of the action working on it, whether a started run has shown up in the log
/// yet, and the run this app holds. It belongs to the thread, so an answer that comes back for another one lands on that one
/// and is never compared against what is on screen.
@MainActor @Observable final class ThreadSession {
    /// A project's thread; a draft being written has no thread yet.
    struct Key: Hashable {
        var projectPath: String
        var thread: String

        init(project: Project, thread: String?) { (projectPath, self.thread) = (project.root.path, thread ?? "") }
    }

    struct OwnedRun {
        var handle: RunHandle
        var project: Project
        var thread: String
    }

    let key: Key
    /// What the app is doing for the person right now, in words; nil when it is waiting for them.
    var busyText: String?
    /// A run was started and the log does not show a newer turn than this one yet (the worktree is being cut, setup is installing):
    /// the text stays up until it does, or the run ends or fails.
    @ObservationIgnored var awaitingAfterTurn: Int?
    /// The run this app started in the thread and has not seen end.
    @ObservationIgnored var ownedRun: OwnedRun?

    init(key: Key) { self.key = key }

    var awaitingRun: Bool { awaitingAfterTurn != nil }
    /// Nothing is going on for the thread: the session can be dropped.
    var isIdle: Bool { busyText == nil && awaitingAfterTurn == nil && ownedRun == nil }
}
