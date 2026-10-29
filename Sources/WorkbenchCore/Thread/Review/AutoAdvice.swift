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

extension ThreadService {
    /// Runs the steps of `[review] auto` that `NextSteps` says are due, in the order the config lists them, one after the other.
    /// Called by whoever started the run once its turn has ended and its runner is gone (`judge` and `review-stage` refuse while one
    /// is live), and only after a turn that succeeded with a check that passed or none. Never throws and never blocks anything:
    /// every answer is recorded by the step itself, and the caller shows `notify` lines as they come.
    public func runAutoAdvice(
        id: String, config: Config, environment: [String: String] = ProcessInfo.processInfo.environment,
        notify: @Sendable (String) -> Void = { _ in }
    ) async -> [AutoAdviceResult] {
        guard !config.review.auto.isEmpty else { return [] }
        var results: [AutoAdviceResult] = []
        for name in config.review.auto {
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
            let result = await runOne(name, id: id, config: config, environment: environment)
            results.append(result)
        }
        return results
    }

    private func runOne(_ name: String, id: String, config: Config, environment: [String: String]) async -> AutoAdviceResult {
        do {
            if name == "judge" {
                let judged = try await judge(id: id, config: config, environment: environment)
                if let failure = judged.failure { return AutoAdviceResult(name: name, outcome: .failed(failure)) }
                let met = judged.verdict?.criteria.filter(\.met).count ?? 0
                let total = judged.verdict?.criteria.count ?? 0
                return AutoAdviceResult(name: name, outcome: .ran(summary: "\(met) of \(total) criteria met"))
            }
            let reviewed = try await reviewStage(named: name, id: id, config: config, environment: environment)
            if let skipped = reviewed.skipped { return AutoAdviceResult(name: name, outcome: .skipped(skipped)) }
            if let failure = reviewed.failure { return AutoAdviceResult(name: name, outcome: .failed(failure)) }
            return AutoAdviceResult(name: name, outcome: .ran(summary: reviewed.verdict.map { "\($0)" } ?? "no verdict"))
        } catch {
            return AutoAdviceResult(name: name, outcome: .failed("\(error)"))
        }
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
