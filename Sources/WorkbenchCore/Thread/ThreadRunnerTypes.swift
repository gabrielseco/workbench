// What a run reports and what it is given: the result, the turn report, the notices and the options of `ThreadRunner.run`.
import Foundation

public enum RunResult: String, Sendable, Equatable {
    case succeeded
    case failed
    case stopped
    case timedOut = "timed_out"
    case budgetExceeded = "budget_exceeded"
    case interrupted
}

public struct TurnReport: Sendable, Equatable {
    public var turn: Int
    public var result: RunResult
    public var exitCode: Int32?
    public var signal: Int32?
    public var durationMs: Int
    public var costUSD: Double?
    public var sessionID: String
    public var permissionDenials: Int
    /// What Claude said last, from the `result` line.
    public var summary: String?
    /// The project's check as Workbench ran it after this turn, nil when none ran.
    public var check: CheckReport?
    /// The verifier turn Workbench ran after the check (`[verifier] auto`), nil when none ran.
    public var verifier: VerifierReport?
}

public enum RunNotice: Sendable {
    case recoveredOrphanedTurn(Int)
    case recoveredOrphanedCheck(Int)
    case sweptOrphans([Int32])
    case turnStarted(turn: Int, pid: Int32?, resume: Bool)
    case activity(String)
    case turnEnded(TurnReport)
    case checkStarted(turn: Int, command: String)
    case checkRan(CheckReport)
    case verifierStarted(turn: Int, skill: String)
    case verifierEnded(VerifierReport)
    case setupStarted(command: String)
    case setupRan(SetupReport)
    /// Something worth a line that is not an error: local edits left out, a base behind its origin.
    case advisory(String)
}

public struct RunOptions: Sendable {
    /// What to tell Claude after a review sent the work back. Required once a turn has succeeded.
    public var feedback: String?
    /// Replaces the goal's `turn_timeout_min`. For tests.
    public var timeoutOverride: TimeInterval?
    /// Replaces the check's timeout, which is otherwise the turn's. For tests.
    public var checkTimeoutOverride: TimeInterval?
    /// Replaces the setup command's timeout (`SetupRunner.defaultTimeout`). For tests.
    public var setupTimeoutOverride: TimeInterval?
    /// Replaces the verifier's timeout (`[verifier] timeout_min`). For tests.
    public var verifierTimeoutOverride: TimeInterval?
    public var killGrace: TimeInterval = 5
    /// Kept so scripts that pass `--allow-dirty` still work; a dirty checkout no longer blocks a run.
    public var allowDirty = false
    /// Run although a proof names a command the tool set would not let the run execute (`ProofCommands`).
    public var allowUnrunnableProofs = false
    /// The budget for this run's turns instead of the goal's. The goal file is not touched.
    public var budgetOverride: Decimal?
    /// Most a single turn may be given by `budgetOverride`.
    public static let budgetCeilingUSD: Decimal = 100
    /// The environment `claude` is derived from. Defaults to this process's.
    public var parentEnvironment: [String: String] = ProcessInfo.processInfo.environment

    /// Leave the thread's plan out of the first prompt (`run --no-plan`).
    public var noPlan = false

    public init(feedback: String? = nil) { self.feedback = feedback }
}
