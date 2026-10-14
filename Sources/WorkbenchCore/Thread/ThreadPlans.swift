import Foundation

/// What a discard would remove, shown before asking.
public struct DiscardPlan: Sendable, Equatable {
    public var id: String
    public var worktree: URL?
    public var branch: String?
    public var diff: ReviewReport.Diff
    /// `--oneline` of the commits on the branch that are not on its base.
    public var commits: [String]
    /// False when git could not list the commits, so the list above may be missing some.
    public var commitsKnown = true

    /// Everything that would be lost was listed: the diff and the commits could be read and were not cut.
    public var fullyShown: Bool {
        guard commitsKnown, commits.count <= 10 else { return false }
        guard case .summary(let summary) = diff else { return worktree == nil }
        return !summary.truncated
    }

    public func render() -> [String] {
        var lines = ["discard \(id) will delete:"]
        if let worktree { lines.append("  worktree  \(worktree.path)") }
        if let branch { lines.append("  branch    \(branch)") }
        switch diff {
        case .summary(let summary):
            if summary.files.isEmpty { lines.append("  no changed files") }
            for file in summary.files { lines.append("  " + ReviewReport.describe(file)) }
            if summary.truncated {
                lines.append("  … and \(summary.totalFiles - summary.files.count) more files not listed")
            }
        case .unavailable(let reason):
            lines.append("  changes not shown: \(reason)")
        }
        if !commitsKnown { lines.append("  commits on the branch could not be listed") }
        if !commits.isEmpty {
            let count = commits.count > 10 ? "more than 10 commits" : "\(commits.count) commit\(commits.count == 1 ? "" : "s")"
            lines.append("  \(count) on the branch, not on its base:")
            for commit in commits.prefix(10) { lines.append("    " + commit) }
            if commits.count > 10 { lines.append("    … more commits not listed; pass --yes to confirm") }
        }
        return lines
    }
}

/// The yes/no before a destructive command, kept out of the CLI so it can be tested.
public enum Confirmation: Equatable, Sendable {
    case proceed
    /// The person said no (or anything but yes). Nothing was changed.
    case declined
    /// No `--yes` and nobody to ask.
    case refused

    public static func ask(yes: Bool, interactive: Bool, readLine: () -> String?) -> Confirmation {
        if yes { return .proceed }
        guard interactive else { return .refused }
        guard let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() else { return .declined }
        return answer == "y" ? .proceed : .declined
    }
}

/// What an accept would commit, shown before it happens.
public struct AcceptPlan: Sendable, Equatable {
    public var id: String
    public var worktree: URL
    public var branch: String
    public var diff: ReviewReport.Diff
    /// Uncommitted work in the worktree, which accept commits.
    public var hasPendingChanges: Bool
    /// Commits already on the branch that are not on its base (at most eleven are listed).
    public var commits: [String]
    public var check: Review.Check?
    /// A turn or check is open (its runner died): accept records it as interrupted.
    public var openWork: Bool
    /// Index and working-file identities, so an edit that keeps paths and line counts still counts as new.
    public var snapshot: String
    public var defaultMessage: String

    /// A check ran and did not pass, or a turn or check was cut off. Accepting is still allowed; it has
    /// to be said out loud.
    public var checkFailed: Bool { openWork || (check.map { $0.result != "passed" } ?? false) }

    public func render() -> [String] {
        var lines = ["accept \(id) will commit to \(branch):"]
        switch diff {
        case .summary(let summary):
            if summary.files.isEmpty { lines.append("  no changed files") }
            for file in summary.files { lines.append("  " + ReviewReport.describe(file)) }
            if summary.truncated {
                lines.append("  … and \(summary.totalFiles - summary.files.count) more files not listed")
            }
        case .unavailable(let reason):
            lines.append("  changes not shown: \(reason)")
        }
        if !commits.isEmpty {
            lines.append("  \(commits.count > 10 ? "more than 10" : String(commits.count)) commit(s) already on the branch")
        }
        if !hasPendingChanges { lines.append("  nothing pending: the commits above are accepted as they are") }
        if openWork {
            lines.append("  a turn or check was cut off; accepting records it as interrupted")
        } else if let check {
            lines.append("  check: \(check.result)\(check.exitCode.map { " (exit \($0))" } ?? "") after turn \(check.turn)")
        } else {
            lines.append("  check: none ran")
        }
        return lines
    }
}

public struct AcceptResult: Sendable, Equatable {
    public var branch: String
    public var commit: String
    /// False when the work was already committed and accept only recorded the decision.
    public var committedNow: Bool
}
