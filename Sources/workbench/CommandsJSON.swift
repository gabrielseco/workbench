import Foundation
import WorkbenchCore

/// The `--json` shapes of `status`, `review` and `log`. Documented in `docs/spec/cli-json.md`; keys are
/// added, never renamed, within a version.
extension Commands {
    static let jsonVersion = 1

    static func statusKeys() -> [String] {
        ["v", "thread", "ended", "goal", "turns", "open_turn", "running", "last_result", "check", "cost_usd",
         "notes", "base_gap", "worktree", "progress"]
    }

    static func reviewKeys() -> [String] {
        ["v", "thread", "status", "ended", "title", "approval", "goal_problem", "turns", "last_result", "cost_usd",
         "base", "worktree", "criteria", "diff", "check", "denied_tools", "notes", "next", "base_gap"]
    }

    private static func gapJSON(_ base: String, ctx: Context) async -> JSONValue {
        let manager = WorktreeManager(repoRoot: ctx.project.root, git: ctx.git)
        guard let gap = await manager.baseGap(base: base) else { return .null }
        return [
            "base": .string(gap.base), "behind": .int(gap.behind),
            "fetch_note": gap.fetchNote.map { .string($0) } ?? .null,
        ]
    }

    static func statusString(_ status: ReviewStatus) -> String {
        switch status {
        case .empty: "empty"
        case .running: "running"
        case .awaitingReview: "awaiting_review"
        case .sentBack: "sent_back"
        case .decided: "decided"
        }
    }

    /// `status --all`: one entry per thread on disk, newest first. Read-only; nothing in it can be started.
    static func statusAllJSON(_ states: [ThreadState]) -> JSONValue {
        [
            "v": .int(jsonVersion),
            "threads": .array(
                states.map { state in
                    [
                        "thread": .string(state.id), "status": .string(statusString(state.review.status)),
                        "ended": state.decision.map { .string($0) } ?? .null,
                        "last_result": state.lastResult.map { .string($0) } ?? .null,
                        "turns": .int(state.lastTurn), "cost_usd": .double(state.totalCostUSD),
                        "parent": state.lineage.map { .string($0.parent) } ?? .null,
                        "root": state.lineage.map { .string($0.root) } ?? .null,
                        "round": state.lineage.map { .int($0.round) } ?? .null,
                    ]
                }),
        ]
    }

    /// Where a review follow-up came from: `{parent, root, round}`, null for a thread someone started.
    static func lineageJSON(_ state: ThreadState) -> JSONValue {
        guard let lineage = state.lineage else { return .null }
        return ["parent": .string(lineage.parent), "root": .string(lineage.root), "round": .int(lineage.round)]
    }

    /// The follow-ups that name this thread as their parent, each with how it stands.
    static func followUpsJSON(id: String, ctx: Context) -> JSONValue {
        .array(
            children(of: id, ctx: ctx).map { child in
                [
                    "thread": .string(child.id), "round": .int(child.lineage?.round ?? 0),
                    "status": .string(statusString(child.review.status)),
                    "ended": child.decision.map { .string($0) } ?? .null,
                    "last_result": child.lastResult.map { .string($0) } ?? .null,
                    "cost_usd": .double(child.totalCostUSD),
                ]
            })
    }

    static func children(of id: String, ctx: Context) -> [ThreadState] {
        ctx.store.followUps(of: ctx.store.rootID(of: id)).filter { $0.lineage?.parent == id }
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
        let worktreeValue = worktreeJSON(id: id, ctx: ctx)
        let progressValue = progressJSON(state: state, id: id, ctx: ctx)
        let gap: JSONValue = if let base { await gapJSON(base, ctx: ctx) } else { .null }
        return [
            "v": .int(jsonVersion), "thread": .string(id), "ended": state.decision.map { .string($0) } ?? .null,
            "lineage": lineageJSON(state), "follow_ups": followUpsJSON(id: id, ctx: ctx),
            "goal": goalValue, "turns": .int(state.lastTurn),
            "open_turn": state.openTurn.map { .int($0) } ?? .null,
            "running": .bool(ctx.service.runnerPID(id: id) != nil),
            "last_result": state.lastResult.map { .string($0) } ?? .null,
            "check": [
                "open_turn": state.openCheck.map { .int($0) } ?? .null,
                "last": state.lastCheck.map { .string($0) } ?? .null,
            ],
            "verify": [
                "open_turn": state.openVerify.map { .int($0) } ?? .null,
                "last": state.review.verify.map { .string($0.result) } ?? .null,
            ],
            "cost_usd": .double(state.totalCostUSD), "notes": noteJSON(state.review.notes), "base_gap": gap,
            "worktree": worktreeValue, "progress": progressValue,
        ]
    }

    /// The open turn's progress; null when no turn is open.
    private static func progressJSON(state: ThreadState, id: String, ctx: Context) -> JSONValue {
        guard let turn = state.openTurn else { return .null }
        let now = Date()
        let p = state.progress
        func seconds(_ value: TimeInterval?) -> JSONValue { value.map { .int(Int($0.rounded())) } ?? .null }
        let age = p.quietFor(now: now)
        return [
            "turn": .int(turn), "elapsed_s": seconds(p.elapsed(now: now)),
            "timeout_s": seconds(turnTimeout(id: id, ctx: ctx)),
            "last_event": p.lastEvent.map { .string($0) } ?? .null, "last_event_age_s": seconds(age),
            "quiet": .bool((age ?? 0) >= Progress.quietThreshold),
            "tool_calls": .int(p.toolCalls), "denied_calls": .int(p.deniedCalls),
        ]
    }

    private static func worktreeJSON(id: String, ctx: Context) -> JSONValue {
        let worktree = ctx.project.worktreesDirectory.appendingPathComponent(id)
        var state = "none"
        if FileManager.default.fileExists(atPath: worktree.path) {
            state = "present"
        } else if let events = try? EventLogReader.read(at: ctx.project.eventsURL(id)).events,
            events.contains(where: { $0.kind == .worktreeRemoved }) {
            state = "removed"
        }
        return ["state": .string(state), "path": .string(worktree.path)]
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
        let verify: JSONValue
        if let v = review.verify {
            verify = [
                "turn": .int(v.turn), "result": .string(v.result), "exit_code": v.exitCode.map { .int($0) } ?? .null,
                "duration_ms": v.durationMs.map { .int($0) } ?? .null,
                "proof": .array(
                    v.proof.map {
                        [
                            "name": .string($0.name), "path": .string($0.path), "sha256": .string($0.sha256),
                            "bytes": .int($0.bytes),
                        ]
                    }),
            ]
        } else {
            verify = .null
        }
        let judge: JSONValue
        if let j = review.judge {
            judge = [
                "turn": .int(j.turn), "ok": .bool(j.verdict != nil), "stale": .bool(j.turn != state.lastTurn),
                "cost_usd": j.costUSD.map { .double($0) } ?? .null, "failure": j.failure.map { .string($0) } ?? .null,
                "criteria": .array(
                    (j.verdict?.criteria ?? []).map {
                        ["id": .string($0.id), "met": .bool($0.met), "evidence": .array($0.evidence.map { .string($0) })]
                    }),
                "concerns": .array((j.verdict?.concerns ?? []).map { .string($0) }),
            ]
        } else {
            judge = .null
        }
        let prReview: JSONValue
        if let r = review.prReview {
            prReview = [
                "round": .int(r.round), "pr": r.pr.map { .int($0) } ?? .null, "verdict": r.verdict.map { .string($0) } ?? .null,
                "ok": .bool(r.verdict != nil), "stale": .bool(report.prReviewIsStale),
                "head_sha": r.headSHA.map { .string($0) } ?? .null, "findings_path": r.findingsPath.map { .string($0) } ?? .null,
                "failure": r.failure.map { .string($0) } ?? .null,
            ]
        } else {
            prReview = .null
        }
        let decision: JSONValue
        if case .decided(let d) = review.status { decision = .string(d) } else { decision = .null }
        let gap: JSONValue = if let base { await gapJSON(base, ctx: ctx) } else { .null }
        return [
            "v": .int(jsonVersion), "thread": .string(state.id), "status": .string(statusString(review.status)),
            "lineage": lineageJSON(state), "follow_ups": followUpsJSON(id: state.id, ctx: ctx),
            "ended": decision, "title": report.title.map { .string($0) } ?? .null,
            "approval": report.approval.map { .string($0) } ?? .null,
            "goal_problem": report.goalProblem.map { .string($0) } ?? .null, "turns": .int(state.lastTurn),
            "last_result": review.turnResult.map { .string($0) } ?? .null, "cost_usd": .double(state.totalCostUSD),
            "base": base.map { .string($0) } ?? .null, "worktree": worktreeJSON(id: state.id, ctx: ctx),
            "criteria": .array(
                zip(report.criteria, report.criterionStatuses).map { criterion, status in
                    [
                        "id": .string(criterion.id), "text": .string(criterion.text),
                        "proof": .string(criterion.proof), "status": .string(status.state.rawValue),
                        "commands": .array(status.commands.map { .string($0) }),
                        "note": status.note.map { .string($0) } ?? .null,
                        "file": status.file.map { .string($0) } ?? .null,
                    ]
                }),
            "diff": diff, "check": check, "verify": verify, "judge": judge,
            "pr_review": prReview,
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
