import Foundation
import WorkbenchCore

/// The thread spine and the "needs you" answer as `status` prints them. `status` never asks GitHub, so no CI-based
/// reason appears here (the app passes the checks it polls).
extension Commands {
    static func goalApproval(id: String, ctx: Context) -> ApprovalState? {
        guard let text = try? String(contentsOf: ctx.project.goalURL(id), encoding: .utf8) else { return nil }
        return (try? GoalFile.parse(text).goal)?.approval
    }

    static func spineLines(_ state: ThreadState, approval: ApprovalState?) -> [String] {
        let spine = ThreadSpine.derive(state: state, goal: approval)
        var lines = spine.entries.enumerated().map { index, entry in
            let head = index == 0 ? "spine:     " : "           "
            let step = entry.step.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0)
            let mark = markName(entry.mark).padding(toLength: 9, withPad: " ", startingAt: 0)
            return (head + step + " " + mark + " " + entry.sublabel).trimmingCharacters(in: .whitespaces)
        }
        switch Attention.derive(state: state) {
        case .none: lines.append("attention: none")
        case .working: lines.append("attention: working")
        case .needsYou(let reason, let since): lines.append("attention: needs you: \(reason) (since \(sinceText(since)))")
        }
        return lines
    }

    static func spineJSON(_ state: ThreadState, approval: ApprovalState?) -> (spine: JSONValue, attention: JSONValue) {
        let spine = ThreadSpine.derive(state: state, goal: approval)
        let entries: JSONValue = .array(
            spine.entries.map {
                ["step": .string($0.step.rawValue), "mark": .string(markName($0.mark)), "sublabel": .string($0.sublabel)]
            })
        let attention: JSONValue =
            switch Attention.derive(state: state) {
            case .none: ["state": "none", "reason": .null, "since": .null]
            case .working: ["state": "working", "reason": .null, "since": .null]
            case .needsYou(let reason, .seq(let seq)): ["state": "needs_you", "reason": .string(reason), "since": .int(seq)]
            case .needsYou(let reason, .commit(let sha)):
                ["state": "needs_you", "reason": .string(reason), "since": .string(sha)]
            }
        return (entries, attention)
    }

    private static func markName(_ mark: ThreadSpine.Mark) -> String {
        mark == .needsYou ? "needs_you" : mark.rawValue
    }

    private static func sinceText(_ since: Attention.Since) -> String {
        switch since {
        case .seq(let seq): "seq \(seq)"
        case .commit(let sha): "commit \(sha.prefix(12))"
        }
    }
}
