import Crypto
import Foundation
import Testing

@testable import WorkbenchCore

private func goalText(spend: String = "budget_usd: 5.00", extra: String = "", approvedHash: String? = nil) -> String {
    let approval = approvedHash.map { "\nstatus: approved\napproved_at: 2026-10-12T20:10:00Z\napproved_hash: \($0)" } ?? ""
    return """
        ---
        id: g-2026-10-12-retry
        title: Retry
        base: main
        \(spend)
        turn_timeout_min: 30\(extra)\(approval)
        ---

        ## Request

        Add retry.

        ## Criteria

        - [c1] It retries.
          - proof: test: SyncTests/retries

        ## Out of scope

        - Uploads.
        """
}

private func problems(_ text: String, knownKeys: Set<String>? = nil) -> [GoalProblem] {
    do {
        _ = try knownKeys.map { try GoalFile.parse(text, knownKeys: $0) } ?? GoalFile.parse(text)
        return []
    } catch let error as GoalParseError {
        return error.problems
    } catch {
        Issue.record("unexpected error \(error)")
        return []
    }
}

@Suite struct GoalSpendPolicyTests {
    /// Computed by hand from the hash recipe of `origin/main` before the key existed:
    /// sha256("workbench-goal-v1\nbase=main\nbudget_usd=5\nturn_timeout_min=30\n---\n" + body).
    private static let approvedBeforeTheKey = "87dbe221958d0e95036d8c259b7544830d0c3069a7b03b59cd7bd1b9ca9837a5"

    @Test func parsesTimeoutOnlyWithoutBudget() throws {
        let goal = try GoalFile.parse(goalText(spend: "spend_policy: timeout_only")).goal
        #expect(goal.spend == .timeoutOnly && goal.isTimeoutOnly)
        #expect(goal.budgetUSD == nil)
        #expect(goal.spendPolicyName == "timeout_only")
        #expect(goal.spendLine == "no dollar cap: bounded by 30 min per turn")
    }

    @Test func absentKeyKeepsBudgetRequired() throws {
        let goal = try GoalFile.parse(goalText()).goal
        #expect(goal.spend == .hardCap(5) && goal.budgetUSD == 5 && goal.spendPolicyName == "hard_cap")
        let missing = problems(goalText(spend: ""))
        #expect(missing.contains { $0.code == .missingKey && $0.message.contains("budget_usd") }, "\(missing)")
    }

    @Test func bothKeysIsAnErrorNamingTheKey() {
        let found = problems(goalText(spend: "budget_usd: 5\nspend_policy: timeout_only"))
        #expect(found.count == 1 && found[0].code == .invalidValue, "\(found)")
        #expect(found[0].message.contains("budget_usd") && found[0].message.contains("spend_policy"))
    }

    @Test func otherValuesAreRefused() {
        for value in ["unlimited", "Timeout_Only", "hard_cap", "\"\""] {
            let found = problems(goalText(spend: "spend_policy: \(value)"))
            #expect(found.count == 1 && found[0].code == .invalidValue, "\(value): \(found)")
            #expect(found[0].message.contains("spend_policy"))
        }
        let empty = problems(goalText(spend: "spend_policy:"))
        #expect(empty.contains { $0.message.contains("spend_policy") }, "\(empty)")
        let twice = problems(goalText(spend: "spend_policy: timeout_only\nspend_policy: timeout_only"))
        #expect(twice.contains { $0.code == .duplicateKey })
    }

    @Test func fixtureOfApprovedGoalStaysApproved() throws {
        let goal = try GoalFile.parse(goalText(approvedHash: Self.approvedBeforeTheKey)).goal
        #expect(goal.contentHash == Self.approvedBeforeTheKey)
        #expect(goal.approval == .approved, "a goal approved before the key existed must not go stale")
    }

    @Test func hashFieldsForTimeoutOnly() throws {
        let capped = try GoalFile.parse(goalText()).goal.contentHash
        let free = try GoalFile.parse(goalText(spend: "spend_policy: timeout_only")).goal.contentHash
        let canonical = (["workbench-goal-v1", "base=main", "spend_policy=timeout_only", "turn_timeout_min=30", "---"]
            + [GoalHash.canonicalBody(bodyOf(goalText()))]).joined(separator: "\n")
        let expected = SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(free == expected, "spend_policy=timeout_only takes the place of the budget_usd line")
        #expect(free != capped)
    }

    @Test func editingTheKeyEitherWayReturnsToDraft() throws {
        let approvedCapped = try GoalFile.parse(goalText()).approving()
        #expect(approvedCapped.goal.approval == .approved)
        // Dropping the cap: swap the budget line for the key, keeping the approval record.
        let dropped = approvedCapped.text.replacingOccurrences(of: "budget_usd: 5.00", with: "spend_policy: timeout_only")
        #expect(try GoalFile.parse(dropped).goal.approval == .stale)

        let approvedFree = try GoalFile.parse(goalText(spend: "spend_policy: timeout_only")).approving()
        #expect(approvedFree.goal.approval == .approved)
        let restored = approvedFree.text.replacingOccurrences(of: "spend_policy: timeout_only", with: "budget_usd: 5.00")
        #expect(try GoalFile.parse(restored).goal.approval == .stale)
    }

    /// An older binary does not list `spend_policy` among its keys, so the goal is refused as having an unknown key.
    @Test func unrecognisedKeyIsRefusedLikeAnOlderBinary() {
        var older = FrontMatterLine.knownKeys
        older.remove("spend_policy")
        let found = problems(goalText(spend: "spend_policy: timeout_only"), knownKeys: older)
        #expect(found.contains { $0.code == .unknownKey && $0.message.contains("spend_policy") }, "\(found)")
        #expect(problems(goalText(), knownKeys: older).isEmpty, "a goal without the key is unaffected")
    }

    @Test func copyCarriesTheKey() throws {
        let copy = try GoalFile.copy(goalText(spend: "spend_policy: timeout_only"))
        #expect(copy.settings.timeoutOnly && copy.settings.budgetUSD == nil)
        #expect(copy.ignoredKeys.contains("spend_policy") == false)
        #expect(throws: GoalCopyValueError.self) { try GoalFile.copy(goalText(spend: "spend_policy: nope")) }
        let both = goalText(spend: "budget_usd: 5\nspend_policy: timeout_only")
        #expect(throws: GoalCopyValueError.self) { try GoalFile.copy(both) }
    }
}

private func bodyOf(_ text: String) -> String {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let closing = lines.indices.dropFirst().first { lines[$0] == "---" }!
    return lines[(closing + 1)...].joined(separator: "\n")
}
