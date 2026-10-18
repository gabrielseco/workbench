import Foundation

/// Who wrote a plan: the plan turn, or a person through `plan edit`.
public enum PlanSource: String, Sendable, Equatable {
    case generated
    case edited
}

/// The newest good plan the log names, before anything is checked against the goal or the disk.
public struct LatestPlan: Sendable, Equatable {
    public var source: PlanSource
    /// The plan file, relative to the thread's folder.
    public var ref: String
    public var sha256: String
    public var bytes: Int
    public var goalHash: String?
    public var baseCommit: String?
}

/// A plan as the first prompt carries it.
public struct PlanForRun: Sendable, Equatable {
    public var text: String
    public var source: PlanSource
    public var sha256: String
    public var bytes: Int
    /// The commit the plan was read at, set only when the run's worktree was cut from another one.
    public var plannedAt: String?
}

/// What `run` does about a plan.
public enum PlanChoice: Sendable, Equatable {
    /// There is none.
    case none
    case use(PlanForRun)
    /// There is one and it is not used, and why.
    case left(String)
}

public enum PlanLookup {
    /// The newest `plan.ended` that kept a plan or `plan.edited`. A later plan that failed does not hide it.
    public static func latest(in events: [Event]) -> LatestPlan? {
        for event in events.reversed() {
            let good = event.kind == .planEdited || (event.kind == .planEnded && event.data["ok"] == true)
            guard good, let ref = event.data["plan_ref"]?.stringValue, let sha = event.data["sha256"]?.stringValue
            else { continue }
            return LatestPlan(
                source: event.kind == .planEdited ? .edited : .generated, ref: ref, sha256: sha,
                bytes: event.data["bytes"]?.intValue ?? 0, goalHash: event.data["goal_hash"]?.stringValue,
                baseCommit: event.data["base_commit"]?.stringValue)
        }
        return nil
    }

    /// The text of a plan, only when the file is still what the log recorded: a file changed outside `plan edit`
    /// is not a plan, because the log is the state.
    public static func text(of plan: LatestPlan, in threadDirectory: URL) -> Result<String, PlanProblem> {
        guard let text = try? String(contentsOf: threadDirectory.appendingPathComponent(plan.ref), encoding: .utf8)
        else { return .failure(.missing(plan.ref)) }
        guard Plan.sha256(text) == plan.sha256 else { return .failure(.changed(plan.ref)) }
        return .success(text)
    }

    /// The plan the first prompt should carry, for a goal whose hash is `goalHash` and a worktree cut from
    /// `currentBase`.
    public static func choose(
        events: [Event], goalHash: String, currentBase: String?, threadDirectory: URL
    ) -> PlanChoice {
        guard let latest = latest(in: events) else { return .none }
        guard latest.goalHash == goalHash else {
            return .left("the latest plan was made for an earlier version of the goal; `workbench plan --again` makes a new one")
        }
        switch text(of: latest, in: threadDirectory) {
        case .failure(let problem): return .left("\(problem)")
        case .success(let text):
            let moved = latest.baseCommit.flatMap { planned in currentBase.flatMap { $0 != planned ? planned : nil } }
            return .use(
                PlanForRun(
                    text: text, source: latest.source, sha256: latest.sha256, bytes: latest.bytes, plannedAt: moved))
        }
    }
}

public enum PlanProblem: Error, Equatable, Sendable, CustomStringConvertible {
    case missing(String)
    case changed(String)

    public var description: String {
        switch self {
        case .missing(let ref): "the plan file \(ref) is missing, so the plan is left out"
        case .changed(let ref): "the plan file \(ref) changed since it was recorded, so the plan is left out"
        }
    }
}
