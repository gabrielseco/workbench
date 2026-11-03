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

        init(project: Project?, thread: String?) { (projectPath, self.thread) = (project?.root.path ?? "", thread ?? "") }
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

    /// The goal of the thread, read with the config; nil without a thread.
    var goal: GoalModel?
    /// The latest turn's review while it awaits one; nil otherwise.
    var review: ReviewModel?
    /// What the last action said when it did not go through.
    var actionError: String? { didSet { said() } }
    /// Something an action did not do that is not a failure, such as files left out of a diff.
    var actionNote: String? { didSet { said() } }
    /// What the last decision did, in words: `Accepted: abc1234 on workbench/x`. Cleared by the next action.
    var notice: String? { didSet { said() } }
    /// What core says Discard would remove, shown for confirmation and passed back as `shown:` exactly as shown.
    var pendingDiscard: DiscardPlan? { didSet { said() } }
    /// Why the last change to the draft goal was refused (shown under its blocks); nil after one that went through.
    var goalEditError: String? { didSet { said() } }
    /// Counts the edits that have ended, so a field whose edit was refused can show what the file has.
    var goalEditSerial = 0
    @ObservationIgnored var goalEdits: Task<Void, Never>?
    /// What is typed in this chat's composer: kept per thread, so a draft survives a visit to another thread.
    var chatDraft = ""
    /// A chat turn is going in this thread (or, under a key with no thread, in a chat the log does not show yet).
    var replying = false
    /// What ends the chat turn this session holds.
    @ObservationIgnored var chatStop: DraftStop?
    /// An approval is going through.
    var starting = false
    /// A turn the user is stopping: set from Stop until the log says it ended.
    var stopping = false

    /// Told when the session has something to show, so a session the window has moved away from is kept for when it comes back.
    @ObservationIgnored var onSaid: (@MainActor (ThreadSession) -> Void)?
    /// Takes what another session of the same thread said, so a result that lands late on a session the window has since
    /// replaced still reaches the one on screen.
    func absorb(_ other: ThreadSession) {
        if let text = other.actionError { (actionError, other.actionError) = (text, nil) }
        if let text = other.actionNote { (actionNote, other.actionNote) = (text, nil) }
        if let text = other.notice { (notice, other.notice) = (text, nil) }
        if let plan = other.pendingDiscard { (pendingDiscard, other.pendingDiscard) = (plan, nil) }
    }

    private func said() { if hasMessages { onSaid?(self) } }

    init(key: Key) { self.key = key }

    var awaitingRun: Bool { awaitingAfterTurn != nil }
    /// Nothing is going on for the thread: the session can be dropped.
    var isIdle: Bool { busyText == nil && awaitingAfterTurn == nil && ownedRun == nil && !replying }
    /// The thread has said something that is still up (an error, a note, a decision's outcome): going back to it shows it again.
    var hasMessages: Bool {
        actionError != nil || actionNote != nil || notice != nil || goalEditError != nil || pendingDiscard != nil
    }
    /// Nothing to remember: not working and nothing to show.
    var isSpent: Bool { isIdle && !hasMessages && chatDraft.isEmpty }
}
