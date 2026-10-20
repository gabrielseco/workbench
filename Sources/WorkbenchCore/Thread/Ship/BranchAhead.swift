import Foundation

/// One commit as `review` and `branch.ahead` list it.
public struct BranchCommit: Sendable, Equatable {
    public var sha: String
    /// Cut at `subjectLimit` characters.
    public var subject: String

    public static let listed = 10
    public static let subjectLimit = 100

    /// The commits in `range` (`<from>..<to>`, both already validated), how many there are and the oldest
    /// `listed` of them, oldest first. Nil when git cannot list them.
    static func oldest(in range: String, at directory: URL, git: GitRunner) async -> (count: Int, commits: [BranchCommit])? {
        guard let counted = try? await git.run(["rev-list", "--count", range], in: directory), counted.succeeded,
            let count = Int(counted.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        // Newest first from git, so skipping the newest leaves the oldest few, read without walking more.
        guard let listed = try? await git.run(
            ["log", "--no-decorate", "--format=%H%x09%s", "--max-count=\(listed)", "--skip=\(max(0, count - listed))", range],
            in: directory), listed.succeeded,
            // A cut listing would be published as if it were whole: better none than a partial one.
            !listed.outputTruncated
        else { return nil }
        let commits = listed.stdout.split(separator: "\n").reversed().map { line in
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            return BranchCommit(
                sha: String(parts[0]), subject: String((parts.count > 1 ? parts[1] : "").prefix(subjectLimit)))
        }
        return (count, commits)
    }
}

/// Commits on `workbench/<id>` after the one `accept` recorded: what `ship` pushes that was never accepted.
public struct BranchAhead: Sendable, Equatable {
    public typealias Commit = BranchCommit

    /// The commit the `accepted` decision recorded.
    public var accepted: String
    public var head: String
    /// How many commits `accepted..head` holds; `commits` lists at most ten of them.
    public var count: Int
    /// Oldest first, at most ten, subjects cut at 100 characters.
    public var commits: [Commit]

    public static let listed = BranchCommit.listed

    /// The line `ship` prints.
    public var note: String {
        "note: \(count) commit(s) were added after accept: "
            + commits.map { String($0.sha.prefix(12)) }.joined(separator: " ")
    }

    /// The `workbench log` line for a `branch.ahead` event's data.
    static func describe(_ data: JSONValue) -> String {
        var listed = 0
        if case .array(let commits)? = data["commits"] { listed = commits.count }
        let count = listed >= Self.listed ? "\(listed)+" : String(listed)
        let accepted = (data["accepted"]?.stringValue ?? "?").prefix(12)
        let tip = (data["head"]?.stringValue ?? "?").prefix(12)
        return "branch ahead of accept: \(count) commit(s) after \(accepted), shipping \(tip)"
    }
}

extension ThreadService {
    /// Appends `branch.ahead` when the branch head is not the accepted commit, once per head, so the log says
    /// the pushed head is not the one that was accepted. Nil when the head is the accepted commit.
    func recordBranchAhead(id: String, plan: ShipPlan) async throws -> BranchAhead? {
        let events = (try? EventLogReader.read(at: project.eventsURL(id)))?.events ?? []
        guard
            let accepted = events.last(where: {
                $0.kind == .reviewDecision && $0.data["decision"]?.stringValue == "accepted"
            })?.data["commit"]?.stringValue,
            accepted.range(of: "^[0-9a-f]{7,64}$", options: .regularExpression) != nil,
            plan.head.range(of: "^[0-9a-f]{7,64}$", options: .regularExpression) != nil,
            !plan.head.hasPrefix(accepted)
        else { return nil }

        // Unreadable (the accepted commit was rewritten away, say): the event still says the head moved.
        let found = await BranchCommit.oldest(in: "\(accepted)..\(plan.head)", at: plan.worktree, git: git)
        let commits = found?.commits ?? []
        let ahead = BranchAhead(accepted: accepted, head: plan.head, count: found?.count ?? 0, commits: commits)

        try await withLog(id) { log in
            // A ship that stopped after this was written and is run again does not record it twice.
            let current = (try? EventLogReader.read(at: project.eventsURL(id)))?.events ?? []
            if current.contains(where: { $0.kind == .branchAhead && $0.data["head"]?.stringValue == plan.head }) { return }
            try await log.append(
                .branchAhead,
                data: [
                    "accepted": .string(accepted), "head": .string(plan.head),
                    "commits": .array(commits.map { .object(["sha": .string($0.sha), "subject": .string($0.subject)]) }),
                ])
        }
        return ahead
    }
}
