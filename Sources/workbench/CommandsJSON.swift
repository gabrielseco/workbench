import Foundation
import WorkbenchCore

/// The `--json` shapes of `status`, `review` and `log`. Documented in `docs/spec/cli-json.md`; keys are
/// added, never renamed, within a version.
extension Commands {
    static let jsonVersion = 1

    static func statusKeys() -> [String] {
        ["v", "thread", "ended", "goal", "turns", "open_turn", "running", "last_result", "check", "cost_usd",
         "notes", "base_gap", "worktree"]
    }

    static func reviewKeys() -> [String] {
        ["v", "thread", "status", "ended", "title", "approval", "goal_problem", "turns", "last_result", "cost_usd",
         "criteria", "diff", "check", "denied_tools", "notes", "next", "base_gap"]
    }

    private static func gapJSON(_ base: String, ctx: Context) async -> JSONValue {
        let manager = WorktreeManager(repoRoot: ctx.project.root, git: ctx.git)
        guard let gap = await manager.baseGap(base: base) else { return .null }
        return [
            "base": .string(gap.base), "behind": .int(gap.behind),
            "fetch_note": gap.fetchNote.map { .string($0) } ?? .null,
        ]
    }

    private static func statusString(_ status: ReviewStatus) -> String {
        switch status {
        case .empty: "empty"
        case .running: "running"
        case .awaitingReview: "awaiting_review"
        case .sentBack: "sent_back"
        case .decided: "decided"
        }
    }

    private static func noteJSON(_ notes: [Review.Note]) -> JSONValue {
        .array(notes.map { ["turn": .int($0.turn), "seq": .int($0.seq), "text": .string($0.text)] })
    }

    static func statusJSON(id: String, ctx: Context) async -> JSONValue {
        let state = ctx.store.state(of: id)
        var goalValue: JSONValue = .null
        var base: String?
        if let text = try? String(contentsOf: ctx.project.goalURL(id), encoding: .utf8) {
            do {
                let goal = try GoalFile.parse(text).goal
                base = goal.base
                let approval: String
                switch goal.approval {
                case .approved: approval = "approved"
                case .draft: approval = "draft"
                case .stale: approval = "stale"
                }
                goalValue = [
                    "title": .string(goal.title), "approval": .string(approval), "base": .string(goal.base),
                    "budget_usd": .double(NSDecimalNumber(decimal: goal.budgetUSD).doubleValue),
                    "turn_timeout_min": .int(goal.turnTimeoutMin), "problems": [],
                ]
            } catch let error as GoalParseError {
                goalValue = [
                    "title": .null, "approval": "invalid", "base": .null, "budget_usd": .null,
                    "turn_timeout_min": .null,
                    "problems": .array(error.description.split(separator: "\n").map { .string(String($0)) }),
                ]
            } catch {}
        }
        let worktree = ctx.project.worktreesDirectory.appendingPathComponent(id)
        var worktreeState = "none"
        if FileManager.default.fileExists(atPath: worktree.path) {
            worktreeState = "present"
        } else if let events = try? EventLogReader.read(at: ctx.project.eventsURL(id)).events,
            events.contains(where: { $0.kind == .worktreeRemoved }) {
            worktreeState = "removed"
        }
        let gap: JSONValue = if let base { await gapJSON(base, ctx: ctx) } else { .null }
        return [
            "v": .int(jsonVersion), "thread": .string(id), "ended": state.decision.map { .string($0) } ?? .null,
            "goal": goalValue, "turns": .int(state.lastTurn),
            "open_turn": state.openTurn.map { .int($0) } ?? .null,
            "running": .bool(ctx.service.runnerPID(id: id) != nil),
            "last_result": state.lastResult.map { .string($0) } ?? .null,
            "check": [
                "open_turn": state.openCheck.map { .int($0) } ?? .null,
                "last": state.lastCheck.map { .string($0) } ?? .null,
            ],
            "cost_usd": .double(state.totalCostUSD), "notes": noteJSON(state.review.notes), "base_gap": gap,
            "worktree": ["state": .string(worktreeState), "path": .string(worktree.path)],
        ]
    }

    static func reviewJSON(_ report: ReviewReport, ctx: Context) async -> JSONValue {
        let state = report.state
        var base: String?
        if let text = try? String(contentsOf: ctx.project.goalURL(state.id), encoding: .utf8) {
            base = (try? GoalFile.parse(text).goal)?.base
        }
        let diff: JSONValue
        switch report.diff {
        case .summary(let summary):
            diff = [
                "state": "summary", "base": .string(summary.base), "total_files": .int(summary.totalFiles),
                "truncated": .bool(summary.truncated), "additions": .int(summary.additions),
                "deletions": .int(summary.deletions),
                "files": .array(
                    summary.files.map { file in
                        [
                            "path": .string(file.path), "old_path": file.oldPath.map { .string($0) } ?? .null,
                            "status": .string(file.status.rawValue), "binary": .bool(file.isBinary),
                            "untracked": .bool(file.isUntracked), "staged": .bool(file.isStaged),
                            "additions": file.additions.map { .int($0) } ?? .null,
                            "deletions": file.deletions.map { .int($0) } ?? .null,
                        ]
                    }),
                "reason": .null,
            ]
        case .unavailable(let reason):
            diff = [
                "state": "unavailable", "base": .null, "total_files": .null, "truncated": .null,
                "additions": .null, "deletions": .null, "files": [], "reason": .string(reason),
            ]
        }
        let review = state.review
        let check: JSONValue
        if let c = review.check {
            check = [
                "turn": .int(c.turn), "result": .string(c.result), "exit_code": c.exitCode.map { .int($0) } ?? .null,
                "duration_ms": c.durationMs.map { .int($0) } ?? .null,
            ]
        } else {
            check = .null
        }
        let decision: JSONValue
        if case .decided(let d) = review.status { decision = .string(d) } else { decision = .null }
        let gap: JSONValue = if let base { await gapJSON(base, ctx: ctx) } else { .null }
        return [
            "v": .int(jsonVersion), "thread": .string(state.id), "status": .string(statusString(review.status)),
            "ended": decision, "title": report.title.map { .string($0) } ?? .null,
            "approval": report.approval.map { .string($0) } ?? .null,
            "goal_problem": report.goalProblem.map { .string($0) } ?? .null, "turns": .int(state.lastTurn),
            "last_result": review.turnResult.map { .string($0) } ?? .null, "cost_usd": .double(state.totalCostUSD),
            "criteria": .array(
                report.criteria.map { ["id": .string($0.id), "text": .string($0.text), "proof": .string($0.proof)] }),
            "diff": diff, "check": check,
            "denied_tools": .array(
                review.deniedTools.map {
                    [
                        "turn": .int($0.turn), "tool": .string($0.tool), "seq": .int($0.seq),
                        "input": $0.input.map { .string($0) } ?? .null,
                    ]
                }),
            "notes": noteJSON(review.notes),
            "next": .string(ReviewReport.nextStep(for: review.status, openTurn: state.openTurn ?? state.openCheck)),
            "base_gap": gap,
        ]
    }

    static func patchJSON(path: String, patch: FilePatch) -> JSONValue {
        var value: [String: JSONValue] = [
            "v": .int(jsonVersion), "path": .string(path), "patch": .null, "binary": false, "too_large_bytes": .null,
        ]
        switch patch {
        case .text(let text): value["patch"] = .string(text)
        case .binary: value["binary"] = true
        case .tooLarge(let bytes): value["too_large_bytes"] = .int(bytes)
        }
        return .object(value)
    }
}
