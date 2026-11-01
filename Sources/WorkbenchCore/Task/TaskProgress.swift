import Foundation

/// What a task run says while its turn goes: the runner's own notices, as short lines (`task run` prints them, the app shows the last one).
/// A coding turn streams a line for every tool call, so those are let through at most every `interval`, and the milestones (a turn, a
/// check, a setup, the verifier) always.
public final class TaskProgress: @unchecked Sendable {
    public static let interval: TimeInterval = 2
    static let maxLine = 240

    private let lock = NSLock()
    private var lastActivity: Date?
    private let now: @Sendable () -> Date
    private let say: @Sendable (String) -> Void

    public init(now: @escaping @Sendable () -> Date = { Date() }, say: @escaping @Sendable (String) -> Void) {
        self.now = now
        self.say = say
    }

    /// Passes a runner notice on as a line, when it has one worth saying.
    public func notice(_ notice: RunNotice) {
        guard let (line, isActivity) = Self.line(for: notice) else { return }
        if isActivity {
            let at = now()
            let skip = lock.withLock { () -> Bool in
                if let last = lastActivity, at.timeIntervalSince(last) < Self.interval { return true }
                lastActivity = at
                return false
            }
            if skip { return }
        }
        say(TaskExplanation.clean(line, limit: Self.maxLine))
    }

    static func line(for notice: RunNotice) -> (String, Bool)? {
        switch notice {
        case .turnStarted(let turn, _, let resume): ("turn \(turn) started" + (resume ? " (resuming)" : ""), false)
        case .activity(let text): (text, true)
        case .checkStarted(_, let command): ("check started: \(command)", false)
        case .checkRan(let check): ("check \(check.result.rawValue)", false)
        case .setupStarted(let command): ("setup started: \(command)", false)
        case .setupRan(let setup): ("setup \(setup.result.rawValue)", false)
        case .verifierStarted(_, let skill): ("verifier started: \(skill)", false)
        case .verifierEnded(let verifier): ("verifier \(verifier.ok ? "passed" : "did not pass")", false)
        case .advisory(let text): ("note: \(text)", false)
        // The turn's end is told by the run itself, once, with its explanation.
        case .turnEnded, .recoveredOrphanedTurn, .recoveredOrphanedCheck, .sweptOrphans: nil
        }
    }
}
