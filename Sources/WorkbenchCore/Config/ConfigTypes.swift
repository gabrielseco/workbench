// The small value types a `Config` is made of: the tool set, app type, permissions mode and PR review settings.
import Foundation

/// The fixed tool set for a project: what `claude` may use, with nothing else negotiable per run.
public struct ToolSet: Sendable, Equatable {
    /// Built-in tools made available at all (`--tools`). Bare names only.
    public var available: [String]
    /// Patterns allowed without a prompt (`--allowedTools`). Bare names or `Name(pattern)`.
    public var allowed: [String]
    /// Patterns always denied (`--disallowedTools`).
    public var denied: [String]
}

/// `app_type` in `.workbench/config.toml`.
public enum AppType: String, Sendable, Equatable, CaseIterable {
    case web
    case desktop
}

/// `permissions`: who decides which commands a run may use without asking.
public enum PermissionsMode: String, Sendable, Equatable, CaseIterable {
    /// Only what `[tools] allowed` lists (and grants add); everything else is denied.
    case allowlist
    /// `claude --permission-mode auto`: its own classifier decides what is safe in the worktree. `[tools] denied` still wins,
    /// and what the classifier rejects is a denial like any other (`workbench grant`). Bash is not confined to the worktree.
    case auto
}

/// `[pr_review]`: the Codex review of a shipped pull request (docs/plan/P5-review-loop.md).
public struct PRReviewConfig: Sendable, Equatable {
    public static let defaultMaxRounds = 3
    public static let maxRoundsCeiling = 10

    /// A repo-relative file of this project's review invariants, read from the pull request's head and added
    /// to the prompt.
    public var checklist: String?
    /// Reviews of one pull request; Workbench counts them from its own log.
    public var maxRounds: Int = PRReviewConfig.defaultMaxRounds

    public init(checklist: String? = nil, maxRounds: Int = PRReviewConfig.defaultMaxRounds) {
        self.checklist = checklist
        self.maxRounds = maxRounds
    }

    /// Why a checklist path cannot be used, nil when it can: it ends up in a path under a checkout.
    static func checklistProblem(_ path: String) -> String? {
        if path.isEmpty || path.contains("\0") || path.contains("\n") || path.contains("\r") {
            return "must be a file path"
        }
        if path.hasPrefix("/") || path.hasPrefix("~") || path.hasPrefix("-") { return "must be a path inside the repository" }
        if path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." || $0.isEmpty }) {
            return "must be a path inside the repository (no '..' or empty parts)"
        }
        return nil
    }
}
