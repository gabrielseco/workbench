import Foundation

/// What `workbench review` shows. Built from the log, the goal file and the worktree's diff; it writes
/// nothing, takes no lock and runs no check, so it is safe while a turn is running.
public struct ReviewReport: Sendable, Equatable {
    public enum Diff: Sendable, Equatable {
        case summary(DiffSummary)
        /// The worktree is gone or the diff could not be read; `reason` says which.
        case unavailable(reason: String)
    }

    public var state: ThreadState
    public var title: String?
    public var criteria: [Criterion]
    /// How the goal stands (`approved`, `draft`, `changed since approval`), nil when the file is not valid.
    public var approval: String?
    /// Why the goal file could not be read; the criteria are then unknown, not empty.
    public var goalProblem: String?
    public var diff: Diff
    /// The thread's directory, to check that a recorded proof file is still there; nil skips the check.
    public var threadDirectory: URL?
    /// Where the thread's branch is now, nil when it is not known (no local branch).
    public var branchTip: String?
    /// Whether the verify step's proof still describes the worktree; nil when there is no proof to judge.
    public var proofFreshness: ProofFreshness?
    /// One entry per criterion: who verifies it, from the log and the goal alone.
    public var criterionStatuses: [CriterionStatus] {
        CriteriaStatus.evaluate(
            criteria: criteria, check: state.review.check, lastTurn: state.lastTurn, verify: state.review.verify,
            proofAvailable: { [threadDirectory] file in threadDirectory.map(file.isAvailable(in:)) ?? true })
    }

    public var status: ReviewStatus { state.review.status }

    public static func nextStep(for status: ReviewStatus, openTurn: Int?) -> String {
        switch status {
        case .empty: "nothing to review yet: no turn has run. Run `workbench run`."
        case .running:
            "turn \(openTurn.map(String.init) ?? "?") is still running. "
                + "Review when it ends (`workbench log -f` follows it)."
        case .awaitingReview: "accept | send-back \"<note>\" | discard"
        case .sentBack: "feedback is recorded and the next turn has not started. Run `workbench run`."
        case .decided(let decision): "nothing to decide: this thread was \(decision)."
        }
    }

    static func freshnessText(_ freshness: ProofFreshness, commit: String?) -> String {
        let at = commit.map { " at \($0.prefix(7))" } ?? ""
        switch freshness {
        case .current: return "proof taken\(at): still describes the work"
        case .stale: return "proof taken\(at): STALE, the work changed after it; run verify again"
        case .unknown: return "proof taken\(at): cannot tell whether the work changed (no tree recorded or not readable)"
        }
    }

    /// True when the branch has moved since the latest pull request review round looked at it.
    public var prReviewIsStale: Bool {
        guard let round = state.review.prReview, let reviewed = round.headSHA, let tip = branchTip else { return false }
        return reviewed != tip
    }

    /// The pull request review's part of the report: nothing when no round has run.
    public func prReviewLines() -> [String] {
        guard let round = state.review.prReview else { return [] }
        let stale = prReviewIsStale ? " · stale: the branch has moved since" : ""
        let sha = round.headSHA.map { " · \($0.prefix(7))" } ?? ""
        var lines: [String]
        if let verdict = round.verdict {
            lines = ["PR review  round \(round.round) · \(verdict == "clean" ? "clean" : "findings to fix")\(sha)\(stale)"]
        } else {
            lines = ["PR review  round \(round.round) · no verdict\(sha)\(stale): \(round.failure ?? "unknown")"]
        }
        if let path = round.findingsPath { lines.append("  findings: \(path)") }
        return lines
    }

    /// The advisory judge's part of the report: nothing when it has not run. It stands beside the criteria and the
    /// check, and where it disagrees with one of them that is said, not resolved.
    public func judgeLines() -> [String] {
        guard let judge = state.review.judge else { return [] }
        let stale = judge.turn == state.lastTurn ? "" : " (turn \(judge.turn); the latest turn is \(state.lastTurn))"
        let cost = judge.costUSD.map { String(format: " · $%.4f", $0) } ?? ""
        guard let verdict = judge.verdict else {
            return ["Judge      no verdict\(stale): \(judge.failure ?? "unknown")"]
        }
        var lines = ["Judge      advisory · turn \(judge.turn)\(cost)\(stale)"]
        for entry in verdict.criteria {
            let first = entry.evidence.first.map { "  " + $0 } ?? ""
            lines.append("  [\(entry.id)] \(entry.met ? "met    " : "not met")\(first)")
            for more in entry.evidence.dropFirst() { lines.append("                 \(more)") }
        }
        for line in disagreements(verdict) { lines.append("  differs: \(line)") }
        for concern in verdict.concerns { lines.append("  concern: \(concern)") }
        return lines
    }

    /// Where the judge says the opposite of something Workbench itself established.
    func disagreements(_ verdict: JudgeVerdict) -> [String] {
        let statuses = Dictionary(uniqueKeysWithValues: criterionStatuses.map { ($0.id, $0.state) })
        return verdict.criteria.compactMap { entry in
            switch (statuses[entry.id], entry.met) {
            case (.passed?, false): "[\(entry.id)] the check passed, the judge says not met"
            case (.failed?, true): "[\(entry.id)] the check failed, the judge says met"
            case (.missing?, true): "[\(entry.id)] the screenshot is missing, the judge says met"
            default: nil
            }
        }
    }

    /// Lines for the terminal, without colour or a trailing newline.
    public func render() -> [String] {
        var lines: [String] = []
        let review = state.review
        lines.append("thread:    \(state.id)")
        if let title { lines.append("goal:      \(title)\(approval.map { "  (\($0))" } ?? "")") }

        var turns = "turns:     \(state.lastTurn)"
        if let result = review.turnResult { turns += "  last \(result)" }
        turns += "  " + Self.costText(state)
        lines.append(turns)
        lines.append(Self.planLine(for: state))

        lines.append("")
        lines.append("Criteria")
        if let goalProblem {
            lines.append("  goal file not valid, criteria unknown:")
            for line in goalProblem.split(separator: "\n") { lines.append("    \(line)") }
        } else if criteria.isEmpty {
            lines.append("  (none)")
        } else {
            for c in criteria {
                lines.append("  [\(c.id)] ☐ \(c.text)")
                if !c.proof.isEmpty { lines.append("         proof: \(c.proof)") }
            }
            // Beside the checklist, not instead of it: which of these Workbench proved and which are yours.
            let statuses = criterionStatuses
            lines.append("")
            lines.append(CriteriaStatus.summary(statuses, check: review.check))
            lines.append(contentsOf: CriteriaStatus.render(statuses))
        }

        lines.append("")
        switch diff {
        case .summary(let summary):
            lines.append("Diff against \(summary.base.prefix(12))")
            if summary.files.isEmpty { lines.append("  no changes") }
            for file in summary.files { lines.append("  " + Self.describe(file)) }
            if summary.truncated {
                lines.append("  too many files, showing \(summary.files.count) of \(summary.totalFiles)")
            }
            if !summary.files.isEmpty {
                // Line counts are only known for the listed files, so say so when the list was cut.
                let noun = summary.totalFiles == 1 ? "file" : "files"
                let counts = "+\(summary.additions) −\(summary.deletions)"
                if summary.truncated {
                    lines.append("  \(summary.totalFiles) \(noun); \(counts) in the \(summary.files.count) listed")
                } else {
                    lines.append("  \(summary.totalFiles) \(noun)  \(counts)")
                }
            }
        case .unavailable(let reason):
            lines.append("Diff unavailable: \(reason)")
        }

        lines.append("")
        if let check = review.check {
            var text = "Check      \(check.result)"
            if let code = check.exitCode { text += " (exit \(code))" }
            text += "  turn \(check.turn)"
            if let ms = check.durationMs { text += "  \(ms / 1000)s" }
            if let ref = check.outputRef { text += "  log: checks/\(ref.split(separator: "/").last ?? "")" }
            lines.append(text)
        } else {
            lines.append("Check      none ran")
        }

        if let verify = review.verify {
            var text = "Verify     \(verify.result)"
            if let code = verify.exitCode { text += " (exit \(code))" }
            text += "  turn \(verify.turn)"
            if let ms = verify.durationMs { text += "  \(ms / 1000)s" }
            if let ref = verify.outputRef { text += "  log: \(ref)" }
            lines.append(text)
            if verify.proof.isEmpty {
                lines.append("  no proof files")
            } else {
                if let freshness = proofFreshness { lines.append("  " + Self.freshnessText(freshness, commit: verify.commit)) }
                for file in verify.proof { lines.append("  \(file.path)  \(file.bytes) bytes") }
            }
        }

        lines.append(contentsOf: judgeLines())
        lines.append(contentsOf: prReviewLines())

        if review.deniedTools.isEmpty {
            lines.append("Denied     none")
        } else {
            let count = review.deniedTools.count
            lines.append("Denied     \(count) tool call\(count == 1 ? "" : "s")")
            // Grouped by what was denied, not by how it is shown: two long inputs that only differ after
            // the cut are still two denials.
            let groups = Dictionary(grouping: review.deniedTools, by: { $0.tool + "\u{0}" + $0.identity })
            for items in groups.values.sorted(by: { $0[0].seq < $1[0].seq }) {
                let label = items[0].label
                let turns = Set(items.map(\.turn)).sorted().map(String.init).joined(separator: ", ")
                let seqs = items.map { String($0.seq) }.joined(separator: ", ")
                lines.append("  \(label) ×\(items.count)  turn \(turns), seq \(seqs)")
                // The label is cut for scanning; the whole command follows when there is more of it.
                if let full = items.lazy.compactMap(\.fullInput).first, full != items[0].input {
                    lines.append(contentsOf: Self.wrap("\(items[0].tool)(\(full))", width: 96).map { "      " + $0 })
                }
            }
            lines.append("  open one with `workbench log \(state.id) --seq <n>`")
            lines.append("  allow one with `workbench grant \(state.id)`")
            let stalled = ["stopped", "timed_out", "failed", "interrupted", "budget_exceeded"]
            if let result = review.turnResult, stalled.contains(result),
                review.deniedTools.contains(where: { $0.turn == state.lastTurn }) {
                lines.append("  turn \(state.lastTurn) ended \(result): denied tools may explain this")
            }
        }
        if !review.notes.isEmpty {
            lines.append("Notes      \(review.notes.count) sent back")
            for note in review.notes { lines.append("  turn \(note.turn): " + Self.oneLine(note.text)) }
        }

        lines.append("")
        lines.append(Self.nextStep(for: review.status, openTurn: state.openTurn ?? state.openCheck))
        return lines
    }

    /// `text` in lines of at most `width` characters, broken at a space when there is one.
    static func wrap(_ text: String, width: Int) -> [String] {
        var lines: [String] = []
        var rest = Substring(text)
        while rest.count > width {
            let window = rest.prefix(width + 1)
            let space = window.lastIndex(of: " ").flatMap { $0 > window.startIndex ? $0 : nil }
            let cut = space ?? window.index(before: window.endIndex)
            lines.append(String(rest[..<cut]))
            rest = rest[cut...].drop(while: { $0 == " " })
        }
        if !rest.isEmpty { lines.append(String(rest)) }
        return lines
    }

    /// A note on one line, cut at 120 characters, for lists.
    /// `$0.3700`, or `$0.4800 (turns $0.3700, plan $0.1100)` when a plan turn cost something.
    public static func costText(_ state: ThreadState) -> String {
        guard state.planCostUSD > 0 else { return String(format: "$%.4f", state.totalCostUSD) }
        return String(
            format: "$%.4f (turns $%.4f, plan $%.4f)", state.totalCostUSD + state.planCostUSD, state.totalCostUSD,
            state.planCostUSD)
    }

    /// The plan, as `status` and `review` say it: who wrote it, what it cost, and whether it fits the approved goal.
    public static func planLine(for state: ThreadState) -> String {
        guard let plan = state.currentPlan else {
            if let attempt = state.plan, !attempt.ok {
                return "plan:      none (the last attempt failed: \(oneLine(attempt.failure ?? "no reason recorded")))"
            }
            return "plan:      none"
        }
        var line = "plan:      \(plan.source.rawValue)"
        if let model = plan.model { line += " (\(model))" }
        if let cost = plan.costUSD { line += String(format: "  $%.4f", cost) }
        if plan.goalHash != state.approvedGoalHash { line += "  stale: made for an earlier version of the goal" }
        return line
    }

    public static func oneLine(_ text: String) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return flat.count > 120 ? String(flat.prefix(119)) + "…" : flat
    }

    static func describe(_ file: FileChange) -> String {
        let mark: String
        switch file.status {
        case .added: mark = file.isUntracked ? "?" : "A"
        case .modified: mark = "M"
        case .deleted: mark = "D"
        case .renamed: mark = "R"
        }
        var text = "\(mark)  \(file.path)"
        if let old = file.oldPath { text = "\(mark)  \(old) → \(file.path)" }
        if file.isBinary {
            text += "  binary"
        } else if file.additions == nil || file.deletions == nil {
            text += "  counts unavailable"
        } else {
            text += "  +\(file.additions ?? 0) −\(file.deletions ?? 0)"
        }
        if file.isStaged { text += "  (staged)" }
        return text
    }

    public static func render(_ patch: FilePatch) -> String {
        switch patch {
        case .text(let text): text
        case .binary: "binary file: no patch"
        case .tooLarge(let bytes): "patch too large to show (\(bytes) bytes)"
        }
    }
}

public struct ReviewLoader: Sendable {
    public let project: Project
    public let git: GitRunner

    public init(project: Project, git: GitRunner) {
        self.project = project
        self.git = git
    }

    public func load(id: String, includeIgnored: Bool = false) async -> ReviewReport {
        let state = ThreadStore(project: project).state(of: id)
        var title: String?
        var criteria: [Criterion] = []
        var goalBase: String?
        var approval: String?
        var problem: String?
        do {
            let goal = try GoalFile.parse(try String(contentsOf: project.goalURL(id), encoding: .utf8)).goal
            title = goal.title
            criteria = goal.criteria
            goalBase = goal.base
            switch goal.approval {
            case .approved: approval = "approved"
            case .draft: approval = "draft"
            case .stale: approval = "changed since approval"
            }
        } catch let error as GoalParseError {
            problem = error.description
        } catch {
            problem = "cannot read the goal file: \(error.localizedDescription)"
        }
        return ReviewReport(
            state: state, title: title, criteria: criteria, approval: approval, goalProblem: problem,
            diff: await diff(id: id, goalBase: goalBase, includeIgnored: includeIgnored),
            threadDirectory: project.threadDirectory(id), branchTip: await branchTip(id),
            proofFreshness: await proofFreshness(state))
    }

    /// Nil unless the latest verify step left proof; then whether the worktree still matches what it saw.
    private func proofFreshness(_ state: ThreadState) async -> ProofFreshness? {
        guard let verify = state.review.verify, !verify.proof.isEmpty else { return nil }
        let manager = WorktreeManager(repoRoot: project.root, git: git)
        // After `ship` the worktree is gone and the branch is what is left: the committed work is what was shipped.
        guard manager.exists(state.id) else {
            guard let tip = await branchTip(state.id) else { return ProofFreshness.of(recordedTree: verify.tree, current: nil) }
            return ProofFreshness.of(
                recordedTree: verify.tree, current: await ProofIdentity.committed(ref: tip, in: project.root, git: git))
        }
        return ProofFreshness.of(
            recordedTree: verify.tree,
            current: await ProofIdentity.of(
                worktree: manager.path(for: state.id), git: git, attributesFrom: recordedBase(state.id)))
    }

    /// Where `workbench/<id>` is, nil when the branch does not exist.
    private func branchTip(_ id: String) async -> String? {
        let result = try? await git.run(
            ["rev-parse", "--verify", "--quiet", "refs/heads/\(WorktreeManager.branch(for: id))"], in: project.root)
        guard let result, result.succeeded else { return nil }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One file's patch, by its path in the diff.
    public func patch(id: String, path: String) async throws -> FilePatch? {
        guard case .summary(let summary) = await diff(id: id, goalBase: nil, limit: Int.max),
            let file = summary.files.first(where: { $0.path == path })
        else { return nil }
        return try await DiffProvider(git: git).patch(
            for: file, worktree: WorktreeManager(repoRoot: project.root, git: git).path(for: id), base: summary.base)
    }

    private func diff(
        id: String, goalBase: String?, limit: Int = DiffProvider.fileLimit, includeIgnored: Bool = false
    ) async -> ReviewReport.Diff {
        let manager = WorktreeManager(repoRoot: project.root, git: git)
        guard manager.exists(id) else {
            let events = (try? EventLogReader.read(at: project.eventsURL(id)))?.events ?? []
            if events.contains(where: { $0.kind == .worktreeRemoved }) {
                return .unavailable(
                    reason: "the worktree was removed after shipping; \(WorktreeManager.branch(for: id)) is kept")
            }
            return .unavailable(reason: "the worktree no longer exists")
        }
        guard let base = recordedBase(id) ?? goalBase else { return .unavailable(reason: "no base commit recorded") }
        do {
            return .summary(
                try await DiffProvider(git: git).summary(
                    worktree: manager.path(for: id), base: base, limit: limit,
                    includeIgnored: includeIgnored, includeStaged: includeIgnored))
        } catch {
            return .unavailable(reason: "\(error)")
        }
    }

    private func recordedBase(_ id: String) -> String? {
        let events = (try? EventLogReader.read(at: project.eventsURL(id)))?.events ?? []
        return events.last { $0.kind == .worktreeCreated }?.data["base_commit"]?.stringValue
    }
}
