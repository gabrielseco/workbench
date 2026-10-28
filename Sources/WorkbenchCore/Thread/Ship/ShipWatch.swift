import Foundation

/// One CI check of a pull request, as `gh pr checks --json name,bucket` reports it.
public struct PRCheck: Sendable, Equatable {
    public var name: String
    /// `pass`, `fail`, `pending`, `skipping` or `cancel`.
    public var bucket: String

    public enum Outcome: Sendable, Equatable {
        case passed, failed, pending
    }

    static let knownBuckets: Set<String> = ["pass", "skipping", "fail", "cancel", "pending"]

    public var outcome: Outcome {
        switch bucket {
        case "pass", "skipping": .passed
        case "fail", "cancel": .failed
        default: .pending
        }
    }
}

public struct PRChecksSummary: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case none, pending, passed, failed
    }

    public var checks: [PRCheck]

    /// A failure ends the wait only when nothing is still running, so the final list is complete.
    public var state: State {
        if checks.isEmpty { return .none }
        if checks.contains(where: { $0.outcome == .pending }) { return .pending }
        return checks.contains(where: { $0.outcome == .failed }) ? .failed : .passed
    }

    /// What a change of state is detected on: the same list in the same order is the same state.
    public var signature: String {
        checks.map { "\($0.name)=\($0.bucket)" }.sorted().joined(separator: "\n")
    }

    /// Parses `gh pr checks --json name,bucket`. Anything that is not that shape is an error, never "none".
    public static func parse(_ json: String) throws -> PRChecksSummary {
        guard let data = json.data(using: .utf8),
            let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { throw ShipError.ghFailed("`gh pr checks` did not answer with a JSON list") }
        var checks: [PRCheck] = []
        for item in list {
            guard let name = item["name"] as? String, let bucket = item["bucket"] as? String,
                PRCheck.knownBuckets.contains(bucket)
            else {
                throw ShipError.ghFailed("`gh pr checks` returned a check without a name or a known bucket")
            }
            checks.append(PRCheck(name: name, bucket: bucket))
        }
        return PRChecksSummary(checks: checks)
    }
}

public enum ShipWatchResult: Sendable, Equatable {
    case passed([PRCheck])
    case failed([PRCheck])
    /// The time limit passed with checks still running.
    case timedOut([PRCheck])
    /// No check appeared within the grace period.
    case noChecks
}

extension ThreadService {
    public static let watchTimeout: TimeInterval = 30 * 60
    public static let watchInterval: TimeInterval = 15
    public static let watchCallTimeout: TimeInterval = 30
    public static let watchNoChecksGrace: TimeInterval = 120
    public static let watchFailureLimit = 3

    /// Follows the CI checks of the thread's recorded PR until none is running or `timeout` passes. Read
    /// only: it writes nothing, and the only command it runs is `gh pr checks <number>`, from the project
    /// root so a removed worktree does not matter. `onChange` gets the summary each time it differs.
    public func watchPR(
        id: String, gh: GitRunner?,
        interval: TimeInterval = ThreadService.watchInterval,
        timeout: TimeInterval = ThreadService.watchTimeout,
        callTimeout: TimeInterval = ThreadService.watchCallTimeout,
        noChecksGrace: TimeInterval = ThreadService.watchNoChecksGrace,
        now: @Sendable () -> Date = { Date() },
        sleep: @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1e9)) },
        onChange: @Sendable (PRChecksSummary) -> Void
    ) async throws -> ShipWatchResult {
        let recorded = try recordedPR(id: id, gh: gh)
        let (number, gh, environment) = (recorded.number, recorded.gh, recorded.environment)

        let started = now()
        var failures = 0
        var lastSignature: String?
        var known: [PRCheck] = []
        while true {
            // The limit is checked before asking again, so a long interval cannot carry past it.
            let remaining = timeout - now().timeIntervalSince(started)
            if lastSignature != nil, remaining <= 0 { return .timedOut(known) }
            do {
                let runner = GitRunner(
                    executable: gh.executable, environment: environment,
                    timeout: max(1, min(callTimeout, remaining)))
                let summary = try await pollChecks(number: number, runner: runner)
                failures = 0
                known = summary.checks
                if summary.signature != lastSignature {
                    lastSignature = summary.signature
                    onChange(summary)
                }
                switch summary.state {
                case .passed: return .passed(summary.checks)
                case .failed: return .failed(summary.checks)
                case .none:
                    if now().timeIntervalSince(started) >= noChecksGrace { return .noChecks }
                case .pending: break
                }
            } catch let error as ShipError {
                failures += 1
                if failures >= Self.watchFailureLimit { throw error }
                // Out of time during a bad poll: the last good answer is the result, not this error.
                if timeout - now().timeIntervalSince(started) <= 0 {
                    if lastSignature != nil { return .timedOut(known) }
                    throw error
                }
            }
            let left = timeout - now().timeIntervalSince(started)
            if left <= 0 {
                if lastSignature != nil { return .timedOut(known) }
                continue
            }
            await sleep(min(interval, left))
        }
    }

    /// The CI checks of the thread's recorded pull request, read once. Read only, like `watchPR`: the one command it runs is
    /// `gh pr checks <number>`, from the project root so a removed worktree does not matter, with `GH_REPO` dropped so it asks
    /// about this repository's pull request. A screen that wants the state now calls this on its own schedule.
    public func prChecks(
        id: String, gh: GitRunner?, callTimeout: TimeInterval = ThreadService.watchCallTimeout
    ) async throws -> PRChecksSummary {
        let recorded = try recordedPR(id: id, gh: gh)
        let runner = GitRunner(executable: recorded.gh.executable, environment: recorded.environment, timeout: callTimeout)
        return try await pollChecks(number: recorded.number, runner: runner)
    }

    /// The pull request `ship` recorded and the environment to ask `gh` about it in.
    private func recordedPR(id: String, gh: GitRunner?) throws -> RecordedPR {
        guard SafeNames.isThreadID(id) else { throw ShipError.invalidName(id) }
        let events = (try? EventLogReader.read(at: project.eventsURL(id)))?.events ?? []
        guard let opened = events.last(where: { $0.kind == .prOpened }),
            let number = opened.data["number"]?.intValue, number > 0
        else { throw ShipError.notShipped }
        guard let gh else { throw ShipError.ghMissing }
        var environment = gh.environment
        environment["GH_REPO"] = nil
        return RecordedPR(number: number, gh: gh, environment: environment)
    }

    private struct RecordedPR {
        var number: Int
        var gh: GitRunner
        var environment: [String: String]
    }

    private func pollChecks(number: Int, runner: GitRunner) async throws -> PRChecksSummary {
        let result: GitResult
        do {
            result = try await runner.run(["pr", "checks", String(number), "--json", "name,bucket"], in: project.root)
        } catch GitError.timedOut(_, let seconds) {
            throw ShipError.gitFailed("`gh pr checks` did not answer in \(Int(seconds))s")
        } catch { throw ShipError.ghMissing }
        // `gh` exits non-zero while checks are pending or failing, but still prints the list.
        let text = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty, result.stderr.lowercased().contains("no checks reported") {
            return PRChecksSummary(checks: [])
        }
        if text.isEmpty || (!result.succeeded && !text.hasPrefix("[")) {
            let why = Self.withoutCredentials(
                result.stderr.trimmingCharacters(in: .whitespacesAndNewlines), environment: runner.environment)
            throw ShipError.ghFailed(why.isEmpty ? "`gh pr checks` exited \(result.status)" : String(why.suffix(500)))
        }
        return try PRChecksSummary.parse(text)
    }
}
