import Foundation

/// What a thread's log says is still due, in the order docs/plan/P11-verified-pipeline.md walks it: the judge, each review
/// stage whose `applies_to` matches the change, then the decision, then `ship`. Read-only and advisory: it runs nothing, and
/// nothing here stops `accept` or `ship`. The log is the state, so a stop, a crash or a command run by hand needs no resume logic.
public struct NextStep: Sendable, Equatable {
    public var name: String
    public var command: String
    public var why: String
}

public enum NextSteps {
    /// `files` is what the thread changed (nil when it could not be read: a stage is then listed as applying, and says so). `head` is
    /// the thread's branch tip (nil when unknown): a stage round that recorded another head did not review what is there now. `id`
    /// goes into every command, so one printed for a named thread never acts on the active one.
    public static func derive(events: [Event], files: [String]?, config: Config?, head: String? = nil, id: String) -> [NextStep] {
        guard let ended = events.last(where: { $0.kind == .turnEnded }), ended.data["result"]?.stringValue == "succeeded" else {
            return []
        }
        // A thread that has ended by any other decision, or whose pull request is open, has nothing left here.
        let decision = events.last {
            $0.kind == .reviewDecision && ThreadState.terminalDecisions.contains($0.data["decision"]?.stringValue ?? "")
        }?.data["decision"]?.stringValue
        if let decision, decision != "accepted" { return [] }
        if events.contains(where: { $0.kind == .prOpened }) { return [] }
        let turn = ended.turn
        // A later turn that has started and not ended (still running, or its runner stopped): the finished one is not current.
        if let open = events.last(where: { $0.kind == .turnStarted }), open.seq > ended.seq {
            return [
                NextStep(
                    name: "wait", command: "workbench log -f \(id)",
                    why: "turn \(open.turn) has started and has no end on record (still running, or its runner stopped)")
            ]
        }
        var steps: [NextStep] = []

        if !events.contains(where: { $0.kind == .judgeRan && $0.turn == turn }) {
            steps.append(
                NextStep(
                    name: "judge", command: "workbench judge \(id)", why: "no judge has run for turn \(turn) (advisory)"))
        }
        for name in config?.review.stages ?? [] where name != ReviewConfig.prReviewStage {
            guard let config, let stage = ReviewStage.named(name, config: config) else { continue }
            if let files, !stage.applies(to: files) { continue }
            let done = events.contains {
                $0.kind == .reviewStageFinished && $0.data["stage"]?.stringValue == name && $0.seq > ended.seq
                    && $0.data["verdict"]?.stringValue != ReviewStage.skippedVerdict
                    && ($0.data["head_sha"]?.stringValue).map { head == nil || $0 == head } != false
            }
            guard !done else { continue }
            let globs = stage.config.appliesTo.joined(separator: ", ")
            let scope =
                files == nil
                ? "the changed files could not be read, so it may apply"
                : (globs.isEmpty ? "it applies to every change" : "the change touches \(globs)")
            steps.append(
                NextStep(
                    name: name, command: "workbench review-stage \(name) \(id)",
                    why: "\(scope); not run on this head since turn \(turn) ended (advisory)"))
        }
        if decision == "accepted" {
            steps.append(NextStep(name: "ship", command: "workbench ship \(id)", why: "accepted, no pull request yet"))
        } else {
            let command = "workbench accept \(id) -m \"<message>\""
            steps.append(NextStep(name: "accept", command: command, why: "or send-back or discard"))
        }
        return steps
    }

    /// The lines `next` and `review` print: the first step is the next one, the others follow it.
    public static func render(_ steps: [NextStep]) -> [String] {
        guard !steps.isEmpty else { return [] }
        let width = steps.map(\.command.count).max() ?? 0
        return steps.enumerated().map { index, step in
            let pad = String(repeating: " ", count: width - step.command.count)
            return (index == 0 ? "next  " : "then  ") + step.command + pad + "  " + step.why
        }
    }
}
