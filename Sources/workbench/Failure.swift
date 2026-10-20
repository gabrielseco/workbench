import Foundation
import WorkbenchCore

/// How a command failed, as a fixed list. The exit code is a function of the kind, one table for every
/// command (`docs/spec/exit-codes.md`); `run` adds 3 to 5 for how a turn ended.
enum FailureKind: String {
    case failed
    case usage
    case invalidConfig = "invalid-config"
    case invalidGoal = "invalid-goal"
    case refused
    case notFound = "not-found"
    case notAccepted = "not-accepted"
    case alreadyShipped = "already-shipped"
    case pushRejected = "push-rejected"
    case checkFailed = "check-failed"
    case noResult = "no-result"
    case findings
    case stopped
    case timedOut = "timed-out"
    case budgetExceeded = "budget-exceeded"

    var code: Int32 {
        switch self {
        case .failed: 1
        case .usage, .invalidConfig, .invalidGoal: 2
        case .stopped: 3
        case .timedOut: 4
        case .budgetExceeded: 5
        case .refused: 6
        case .notFound: 7
        case .notAccepted: 10
        case .alreadyShipped: 11
        case .pushRejected: 12
        case .checkFailed: 13
        case .noResult: 14
        case .findings: 15
        }
    }
}

/// Process-wide output mode, set once in `main` before any command runs.
enum Output {
    nonisolated(unsafe) static var json = false
}

/// Prints the failure in the active mode and returns its exit code. Text mode: one line on stderr,
/// `workbench: <kind>: <message>`. JSON mode: one object on stdout and nothing on stderr.
@discardableResult
func fail(_ kind: FailureKind, _ message: String) -> Int32 {
    if Output.json {
        let object: JSONValue = [
            "v": 1,
            "error": ["kind": .string(kind.rawValue), "code": .int(Int(kind.code)), "message": .string(message)],
        ]
        printJSON(object)
    } else {
        // One line: a goal's problems or a remote's message are joined, so a reader of stderr gets one record.
        let oneLine = message.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "; ")
        err("workbench: \(kind.rawValue): \(oneLine)")
    }
    return kind.code
}

func printJSON(_ value: JSONValue) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    if let data = try? encoder.encode(value) { out(String(decoding: data, as: UTF8.self)) }
}

extension ShipError {
    var failureKind: FailureKind {
        switch self {
        case .notAccepted: .notAccepted
        case .alreadyShipped: .alreadyShipped
        case .pushRejected, .remoteDiverged, .branchMoved: .pushRejected
        case .running, .worktreeMissing, .wrongBranch, .uncommitted, .noOrigin, .ghMissing, .ghNotAuthenticated,
            .notPushed, .changedSinceShown, .changedAfterPush, .goalUnreadable, .pushDestinationDiffers, .notShipped,
            .pushTargetMissing, .noPullRequest, .pullRequestTextChanged:
            .refused
        case .invalidName: .usage
        case .remoteUnreachable, .gitFailed, .ghFailed, .pullRequestBehind, .ghEditFailed: .failed
        }
    }
}

/// The kind an error from the core falls under. Anything not listed is a plain failure.
func failureKind(of error: Error) -> FailureKind {
    switch error {
    case let e as CLIError:
        switch e {
        case .usage: return .usage
        case .refused: return .refused
        case .notFound: return .notFound
        case .message: return .failed
        }
    case is ConfigError: return .invalidConfig
    case is GoalParseError: return .invalidGoal
    case let e as ShipError: return e.failureKind
    case let e as GrantError:
        if case .notFound = e { return .notFound }
        return .refused
    case let e as ThreadStoreError:
        if case .invalidName = e { return .usage }
        return .refused
    case let e as ThreadServiceError:
        switch e {
        case .goalInvalid: return .invalidGoal
        case .copyValueInvalid: return .usage
        case .acceptIncomplete, .discardIncomplete: return .failed
        default: return .refused
        }
    case let e as RunnerError:
        if case .claudeNotFound = e { return .failed }
        if case .goalInvalid = e { return .invalidGoal }
        if case .setupFailed = e { return .failed }
        return .refused
    default: return .failed
    }
}
