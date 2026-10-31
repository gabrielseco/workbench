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
    /// `--model` for every turn of this thread; nil falls back to `[agents.run] model`, then the provider's default.
    public var model: String?
    /// An existing branch the thread's work is pushed to by `ship`, instead of a new `workbench/<id>` branch.
    public var pushTo: String?
    /// Steps that do not run for this goal: `verifier`, `judge`, or a stage named in `[review] stages`.
    public var skip: [String] = []
    /// Other checkouts this goal's runs may read, read-only, on top of the config's `read_also` (`ReadAlso`).
    public var readAlso: [String] = []
    /// `quick: true`: the request alone says what to do, so the goal may have no criteria. One with none has no judge or verifier.
    public var quick = false
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

    /// Whether the goal turns `step` off (`verifier`, `judge` or a review stage's name).
    public func skips(_ step: String) -> Bool { skip.contains(step) }

    public var isTimeoutOnly: Bool { spend == .timeoutOnly }

    /// Why `step` cannot run for this goal whatever `skip` says, nil when it can: the judge and the verifier report on
    /// criteria, and a quick goal may have none.
    public func unavailable(_ step: String) -> String? {
        guard criteria.isEmpty else { return nil }
        switch step {
        case "judge": return Self.noCriteriaJudge
        case "verifier": return Self.noCriteriaVerifier
        default: return nil
        }
    }

    public static let noCriteriaJudge =
        "the goal has no criteria (a quick goal), so there is nothing to judge against; add a criterion to judge it"
    public static let noCriteriaVerifier =
        "the goal has no criteria (a quick goal), so there is nothing for the verifier to show"

    /// The steps that do not run for this goal: the ones it skips, then the ones it cannot have.
    public var stepsOff: [String] {
        skip + ["verifier", "judge"].filter { !skip.contains($0) && unavailable($0) != nil }
    }

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
    /// `spend_policy`, `turn_timeout_min`, `model`, `push_to`, `skip`, `read_also`, `quick`). This is what approval binds.
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
        skip: [String] = [], readAlso: [String] = [], quick: Bool = false, body: String
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
        // Like `model`, only when set; sorted, so the order the person lists the steps in does not revoke an approval.
        if !skip.isEmpty { fields.append("skip=\(skip.sorted().joined(separator: ","))") }
        // A wider read surface is something the person approves; sorted for the same reason.
        if !readAlso.isEmpty { fields.append("read_also=\(readAlso.sorted().joined(separator: ","))") }
        // Only when set: it lets the goal run without criteria, which is something the person approves.
        if quick { fields.append("quick=true") }
        let canonical = (fields + ["---", canonicalBody(body)]).joined(separator: "\n")
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
