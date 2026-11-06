import Foundation
import WorkbenchCore

/// What a run's detail says, as labelled lines and notes, before any view: how long it took, what it cost, how setup and the check
/// went, what it was refused and what the agent said last. Pure, so the words are tested without a window.
struct RunDetailFacts: Equatable {
    struct Fact: Equatable {
        var label: String
        var value: String
        /// A command, a count or output: set in the monospaced step; the agent's words are not.
        var mono = false
    }

    var facts: [Fact]
    /// The end of the check's output, when it did not pass.
    var checkTail: [String]
    /// Why there is little to show (no thread, or it is gone), nil when there is not.
    var note: String?

    static func make(_ detail: TaskRunDetail, running: Bool) -> RunDetailFacts {
        var facts: [Fact] = []
        facts.append(Fact(label: "took", value: detail.duration.map(duration) ?? (running ? "still going" : "unknown")))
        // A run that has not ended has no outcome yet, whatever its thread has recorded so far (shipping goes on after the turn).
        if running {
            return RunDetailFacts(facts: facts, checkTail: [], note: "It has not ended: what it did is shown when it has.")
        }
        var note: String?
        switch detail.source {
        case .noThread: note = "This run started no thread, so there is nothing more to show."
        case .removed: note = "Its thread was removed, so setup, the check and what the agent said are gone."
        case .read:
            facts.append(Fact(label: "cost", value: detail.costUSD.map { String(format: "$%.2f", $0) } ?? "unknown"))
        }
        if let setup = detail.setup { facts.append(Fact(label: "setup", value: step(setup.result, setup.seconds))) }
        if let check = detail.check { facts.append(Fact(label: "check", value: step(check.result, check.seconds))) }
        if detail.denied > 0 {
            facts.append(Fact(label: "refused", value: "\(detail.denied) tool call\(detail.denied == 1 ? "" : "s")"))
        }
        if let message = detail.agentMessage { facts.append(Fact(label: "agent said", value: message)) }
        return RunDetailFacts(facts: facts, checkTail: detail.check?.tail ?? [], note: note)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return total >= 60 ? "\(total / 60)m \(total % 60)s" : "\(total)s"
    }

    private static func step(_ result: String, _ seconds: Int?) -> String {
        seconds.map { "\(result) (\($0)s)" } ?? result
    }
}
