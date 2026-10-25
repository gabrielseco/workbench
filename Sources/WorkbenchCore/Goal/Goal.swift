import Crypto
import Foundation

public enum GoalStatus: String, Sendable, Equatable {
    case draft
    case approved
}

/// Where a goal stands relative to its approval.
public enum ApprovalState: Sendable, Equatable {
    /// Never approved.
    case draft
    /// Approved and unchanged since: this is the only state the runner accepts.
    case approved
    /// Marked approved, but the hash is missing or no longer matches the content. Back to draft.
    case stale
}

public struct Criterion: Sendable, Equatable {
    public var id: String
    public var text: String
    public var proof: String
}

public struct Goal: Sendable, Equatable {
    public var id: String
    public var title: String
    /// What the file says. Use `approval` to know whether it still holds.
    public var declaredStatus: GoalStatus
    public var base: String
    /// How the thread's spend is bounded: `budget_usd` as a hard cap, or `spend_policy: timeout_only`.
    public var spend: AgentSpend
    public var turnTimeoutMin: Int
    /// `--model` for every turn of this thread; nil falls back to the config's `model`, then the CLI default.
    public var model: String?
    /// An existing branch the thread's work is pushed to by `ship`, instead of a new `workbench/<id>` branch.
    public var pushTo: String?
    public var approvedAt: String?
    public var approvedHash: String?

    public var request: String
    public var criteria: [Criterion]
    public var outOfScope: [String]

    /// The dollar cap, nil for a `timeout_only` goal.
    public var budgetUSD: Decimal? {
        if case .hardCap(let budget) = spend { return budget }
        return nil
    }

    public var isTimeoutOnly: Bool { spend == .timeoutOnly }

    /// The wording logs and `--json` use: `hard_cap` or `timeout_only`.
    public var spendPolicyName: String { isTimeoutOnly ? "timeout_only" : "hard_cap" }

    /// What `goal approve`, `status`, `review` and `doctor` print where a budget used to be.
    public var spendLine: String {
        switch spend {
        case .hardCap(let budget): "$\(budget) per turn, timeout \(turnTimeoutMin) min"
        case .timeoutOnly: "no dollar cap: bounded by \(turnTimeoutMin) min per turn"
        }
    }

    /// Hash of the body and the front matter fields that change what runs (`base`, `budget_usd` or
    /// `spend_policy`, `turn_timeout_min`, `model`, `push_to`). This is what approval binds.
    public var contentHash: String

    public var approval: ApprovalState {
        guard declaredStatus == .approved else { return .draft }
        return approvedHash == contentHash ? .approved : .stale
    }

    /// The status the rest of the system should act on.
    public var status: GoalStatus { approval == .approved ? .approved : .draft }
}

enum GoalHash {
    static let version = "workbench-goal-v1"

    /// Whitespace-only edits (CRLF, trailing spaces, blank lines at the edges) do not revoke approval;
    /// any change to the words does.
    static func canonicalBody(_ body: String) -> String {
        var lines = body.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                var s = String(line)
                while let last = s.last, last == " " || last == "\t" { s.removeLast() }
                return s
            }
        while lines.first?.isEmpty == true { lines.removeFirst() }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    static func hash(
        base: String, spend: AgentSpend, turnTimeoutMin: Int, model: String? = nil, pushTo: String? = nil,
        body: String
    ) -> String {
        // The model line exists only when set, so a goal without one keeps the hash it was approved with.
        // `spend_policy` replaces the `budget_usd` line only when set, so a goal with a cap keeps its hash.
        var fields = [version, "base=\(base)"]
        switch spend {
        case .hardCap(let budget): fields.append("budget_usd=\(NSDecimalNumber(decimal: budget).stringValue)")
        case .timeoutOnly: fields.append("spend_policy=timeout_only")
        }
        fields.append("turn_timeout_min=\(turnTimeoutMin)")
        if let model { fields.append("model=\(model)") }
        if let pushTo { fields.append("push_to=\(pushTo)") }
        let canonical = (fields + ["---", canonicalBody(body)]).joined(separator: "\n")
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
