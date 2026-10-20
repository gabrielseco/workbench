import Foundation

/// Commits on `workbench/<id>` after the one `accept` recorded: what `ship` pushes that was never accepted.
public struct BranchAhead: Sendable, Equatable {
    public struct Commit: Sendable, Equatable {
        public var sha: String
        public var subject: String
    }

    /// The commit the `accepted` decision recorded.
    public var accepted: String
    public var head: String
    /// How many commits `accepted..head` holds; `commits` lists at most ten of them.
    public var count: Int
    /// Oldest first, at most ten, subjects cut at 100 characters.
    public var commits: [Commit]

    public static let listed = 10
    public static let subjectLimit = 100

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

        let range = "\(accepted)..\(plan.head)"
        var count = 0
        if let counted = try? await git.run(["rev-list", "--count", range], in: plan.worktree), counted.succeeded {
            count = Int(counted.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        }
        // Bounded: --reverse applies after --max-count, so this is the newest ones, put oldest first.
        var commits: [BranchAhead.Commit] = []
        if let listed = try? await git.run(
            ["log", "--reverse", "--max-count=1000", "--no-decorate", "--format=%H%x09%s", range], in: plan.worktree),
            listed.succeeded, listed.stdout.utf8.count < GitRunner.outputLimit {
            commits = listed.stdout.split(separator: "\n").prefix(BranchAhead.listed).map { line in
                let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
                return BranchAhead.Commit(
                    sha: String(parts[0]),
                    subject: String((parts.count > 1 ? parts[1] : "").prefix(BranchAhead.subjectLimit)))
            }
        }
        let ahead = BranchAhead(accepted: accepted, head: plan.head, count: max(count, commits.count), commits: commits)

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
