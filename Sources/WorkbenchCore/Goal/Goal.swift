import CryptoKit
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
    public var budgetUSD: Decimal
    public var turnTimeoutMin: Int
    public var approvedAt: String?
    public var approvedHash: String?

    public var request: String
    public var criteria: [Criterion]
    public var outOfScope: [String]

    /// Hash of the body and the front matter fields that change what runs (`base`, `budget_usd`,
    /// `turn_timeout_min`). This is what approval binds.
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

    static func hash(base: String, budgetUSD: Decimal, turnTimeoutMin: Int, body: String) -> String {
        let canonical = [
            version,
            "base=\(base)",
            "budget_usd=\(NSDecimalNumber(decimal: budgetUSD).stringValue)",
            "turn_timeout_min=\(turnTimeoutMin)",
            "---",
            canonicalBody(body),
        ].joined(separator: "\n")
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
