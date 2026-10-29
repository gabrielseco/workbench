import Foundation

/// What one `[review] auto` entry did. Advice is advisory: a failure here is a line to show, never a failure of the turn it follows.
public struct AutoAdviceResult: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        /// It ran and recorded its own event; `summary` is one line about its answer.
        case ran(summary: String)
        /// It was not started: not due (done already for this turn and head), or nothing to look at.
        case skipped(String)
        /// It was started or refused, and there is no answer; the reason is also in the thread's log where the step records one.
        case failed(String)
    }

    public var name: String
    public var outcome: Outcome
}

/// How a stop reaches the advice a run is followed by: the runner that ended is no longer the thing to stop. The front end hands the
/// same holder to the signal handler (or the app's Stop) and to `runAutoAdvice`, which attaches each running agent to it and
/// starts no further step once it was asked.
public final class AdviceStop: @unchecked Sendable {
    private let lock = NSLock()
    private var requested = false
    private var running: AgentExecution?

    public init() {}

    public var isRequested: Bool { lock.withLock { requested } }

    public func attach(_ execution: AgentExecution) {
        let stopNow = lock.withLock {
            running = execution
            return requested
        }
        if stopNow { execution.stop() }
    }

    public func stop() {
        let current = lock.withLock {
            requested = true
            return running
        }
        current?.stop()
    }
}

extension ThreadService {
    /// Runs the steps of `[review] auto` that `NextSteps` says are due, in the order the config lists them, one after the other.
    /// Called by whoever started the run once its turn has ended and its runner is gone (`judge` and `review-stage` refuse while one
    /// is live), and only after a turn that succeeded with a check that passed or none. Never throws and never blocks anything:
    /// every answer is recorded by the step itself, and the caller shows `notify` lines as they come.
    public func runAutoAdvice(
        id: String, config: Config, environment: [String: String] = ProcessInfo.processInfo.environment,
        stop: AdviceStop = AdviceStop(), notify: @Sendable (String) -> Void = { _ in }
    ) async -> [AutoAdviceResult] {
        guard !config.review.auto.isEmpty else { return [] }
        var results: [AutoAdviceResult] = []
        for name in config.review.auto {
            if stop.isRequested {
                results.append(AutoAdviceResult(name: name, outcome: .skipped("stopped")))
                continue
            }
            // Each step is judged due on the log as it is now: an earlier step may have changed it.
            let report = await ReviewLoader(project: project, git: git).load(id: id)
            let stepKinds: [NextStep.Kind] = [.judge, .stage]
            let due = report.nextSteps.contains { $0.name == name && stepKinds.contains($0.kind) }
            guard due else {
                let why = "not due: done for this turn and head, or it does not apply"
                results.append(AutoAdviceResult(name: name, outcome: .skipped(why)))
                continue
            }
            notify("auto: running \(name)")
            let result = await runOne(name, id: id, config: config, environment: environment, stop: stop)
            results.append(result)
        }
        return results
    }

    private func runOne(
        _ name: String, id: String, config: Config, environment: [String: String], stop: AdviceStop
    ) async -> AutoAdviceResult {
        do {
            if name == "judge" {
                let judged = try await judge(id: id, config: config, environment: environment, attach: { stop.attach($0) })
                if let failure = judged.failure { return AutoAdviceResult(name: name, outcome: .failed(failure)) }
                let met = judged.verdict?.criteria.filter(\.met).count ?? 0
                let total = judged.verdict?.criteria.count ?? 0
                return AutoAdviceResult(name: name, outcome: .ran(summary: "\(met) of \(total) criteria met"))
            }
            // A stage reads the branch's commits. A Codex turn leaves its work uncommitted until `accept`, and a Claude turn that
            // left nothing has no commit either: a stage run now would read an older or empty diff and could say `clean` about it.
            if let why = await uncommittedWork(id: id) {
                return AutoAdviceResult(
                    name: name,
                    outcome: .skipped("\(why); run `workbench review-stage \(name) \(id)` once it is committed (after accept)"))
            }
            let reviewed = try await reviewStage(
                named: name, id: id, config: config, codexPath: config.executable(for: .codex), environment: environment,
                stopRequested: { stop.isRequested }, attach: { stop.attach($0) })
            if let skipped = reviewed.skipped { return AutoAdviceResult(name: name, outcome: .skipped(skipped)) }
            if let failure = reviewed.failure { return AutoAdviceResult(name: name, outcome: .failed(failure)) }
            return AutoAdviceResult(name: name, outcome: .ran(summary: reviewed.verdict.map { "\($0)" } ?? "no verdict"))
        } catch {
            return AutoAdviceResult(name: name, outcome: .failed("\(error)"))
        }
    }

    /// Why the thread's branch does not yet hold the finished turn's work, nil when it does: edits are uncommitted in the worktree,
    /// or the branch has no commit past the base the stage compares with.
    private func uncommittedWork(id: String) async -> String? {
        let worktree = WorktreeManager(repoRoot: project.root, git: git).path(for: id)
        guard let status = try? await git.run(["status", "--porcelain"], in: worktree), status.succeeded else { return nil }
        if !status.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "the turn left changes uncommitted" }
        guard let events = try? EventLogReader.read(at: project.eventsURL(id)).events,
            let base = events.last(where: { $0.kind == .worktreeCreated })?.data["base_commit"]?.stringValue,
            let ahead = try? await git.run(["rev-list", "--count", "\(base)..HEAD"], in: worktree), ahead.succeeded
        else { return nil }
        let count = ahead.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return count == "0" ? "the branch has no commit past its base" : nil
    }

    /// The lines a front end prints for `results`, one per step.
    public static func describe(_ results: [AutoAdviceResult]) -> [String] {
        results.map { result in
            switch result.outcome {
            case .ran(let summary): "auto \(result.name): \(summary)"
            case .skipped(let why): "auto \(result.name): skipped, \(why)"
            case .failed(let why): "auto \(result.name): no answer, \(why)"
            }
        }
    }
}
