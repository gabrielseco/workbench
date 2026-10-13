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

    /// Lines for the terminal, without colour or a trailing newline.
    public func render() -> [String] {
        var lines: [String] = []
        let review = state.review
        lines.append("thread:    \(state.id)")
        if let title { lines.append("goal:      \(title)\(approval.map { "  (\($0))" } ?? "")") }

        var turns = "turns:     \(state.lastTurn)"
        if let result = review.turnResult { turns += "  last \(result)" }
        turns += String(format: "  $%.4f", state.totalCostUSD)
        lines.append(turns)

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
                let noun = summary.totalFiles == 1 ? "file" : "files"
                lines.append("  \(summary.totalFiles) \(noun)  +\(summary.additions) −\(summary.deletions)")
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

        let denied = Dictionary(grouping: review.deniedTools, by: \.tool)
        if denied.isEmpty {
            lines.append("Denied     none")
        } else {
            let parts = denied.sorted { $0.key < $1.key }.map { tool, items -> String in
                let seqs = items.map { String($0.seq) }.joined(separator: ", ")
                return "\(tool) ×\(items.count) (seq \(seqs))"
            }
            lines.append("Denied     " + parts.joined(separator: "; "))
        }
        if !review.notes.isEmpty { lines.append("Notes      \(review.notes.count) sent back") }

        lines.append("")
        lines.append(Self.nextStep(for: review.status, openTurn: state.openTurn ?? state.openCheck))
        return lines
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
        } else {
            text += "  +\(file.additions ?? 0) −\(file.deletions ?? 0)"
        }
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

    public func load(id: String) async -> ReviewReport {
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
            diff: await diff(id: id, goalBase: goalBase))
    }

    /// One file's patch, by its path in the diff.
    public func patch(id: String, path: String) async throws -> FilePatch? {
        guard case .summary(let summary) = await diff(id: id, goalBase: nil, limit: Int.max),
            let file = summary.files.first(where: { $0.path == path })
        else { return nil }
        return try await DiffProvider(git: git).patch(
            for: file, worktree: WorktreeManager(repoRoot: project.root, git: git).path(for: id), base: summary.base)
    }

    private func diff(id: String, goalBase: String?, limit: Int = DiffProvider.fileLimit) async -> ReviewReport.Diff {
        let manager = WorktreeManager(repoRoot: project.root, git: git)
        guard manager.exists(id) else { return .unavailable(reason: "the worktree no longer exists") }
        guard let base = recordedBase(id) ?? goalBase else { return .unavailable(reason: "no base commit recorded") }
        do {
            return .summary(
                try await DiffProvider(git: git).summary(worktree: manager.path(for: id), base: base, limit: limit))
        } catch {
            return .unavailable(reason: "\(error)")
        }
    }

    private func recordedBase(_ id: String) -> String? {
        let events = (try? EventLogReader.read(at: project.eventsURL(id)))?.events ?? []
        return events.last { $0.kind == .worktreeCreated }?.data["base_commit"]?.stringValue
    }
}
