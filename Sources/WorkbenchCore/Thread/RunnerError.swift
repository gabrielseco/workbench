import Foundation

public enum RunnerError: Error, Equatable, Sendable, CustomStringConvertible {
    case noActiveThread
    case goalMissing(String)
    case goalInvalid(String)
    case goalNotApproved(ApprovalState)
    case feedbackRequired
    case feedbackWithoutPriorTurn
    case emptyFeedback
    case invalidBudget(String)
    case alreadyRunning
    case claudeNotFound(String)
    case threadEnded(String)
    /// A proof names a command the run could not execute; the lines say which and what to add.
    case unrunnableProofs(String)
    /// Setup did not pass; no turn was started. `output` is its tail, `hint` empty or a likely cause.
    case setupFailed(command: String, how: String, output: String, hint: String)

    public var description: String {
        switch self {
        case .noActiveThread: "there is no active thread. Start one with `workbench goal new <name>`."
        case .goalMissing(let path): "no goal at \(path)"
        case .goalInvalid(let problems): "the goal is not valid:\n\(problems)"
        case .unrunnableProofs(let lines): "the goal's proofs name commands this run cannot execute:\n\(lines)"
        case .goalNotApproved(let state):
            switch state {
            case .stale:
                "the goal changed since it was approved. Review it and run `workbench goal approve` again."
            default: "the goal is not approved. Run `workbench goal approve`."
            }
        case .feedbackRequired:
            "this thread already has a successful turn. Say what to change: `workbench run --feedback \"...\"`."
        case .feedbackWithoutPriorTurn: "there is nothing to send feedback on yet; run the goal first."
        case .emptyFeedback: "the note is empty. Say what should change."
        case .invalidBudget(let why): "the budget is not usable: \(why)"
        case .alreadyRunning: "another `workbench run` holds this thread's log."
        case .claudeNotFound(let name): "cannot find `\(name)` on PATH. Set claude_path in .workbench/config.toml."
        case .threadEnded(let decision): "this thread has ended (\(decision))."
        case .setupFailed(let command, let how, let output, let hint):
            "setup `\(command)` \(how), so no turn was started. The worktree is kept; fix it and run again."
                + (output.isEmpty ? "" : "\n\(output)") + (hint.isEmpty ? "" : "\n\(hint)")
        }
    }
}
