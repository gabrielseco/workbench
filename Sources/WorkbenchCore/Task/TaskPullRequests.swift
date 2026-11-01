import Foundation

/// What became of the pull requests earlier runs opened, as GitHub says. A unit whose state cannot be found out stays out of the
/// way (`PendingUnits.select`): the answer is nil, never a guess.
enum TaskPullRequests {
    /// What became of the pull request of each thread, by `gh pr list --head workbench/<thread> --state all`: the branch a thread ships
    /// to is the one name Workbench is sure of. A thread GitHub could not be asked about has no entry.
    static func threadStates(threads: Set<String>, gh: GitRunner?, project: Project) async -> [String: UnitPullRequest] {
        guard let gh else { return [:] }
        var byThread: [String: UnitPullRequest] = [:]
        for thread in threads where SafeNames.isThreadID(thread) {
            let result = try? await gh.run(
                ["pr", "list", "--head", "workbench/\(thread)", "--state", "all", "--json", "state", "--limit", "5"],
                in: project.root)
            guard let result, result.succeeded, !result.outputTruncated,
                let value = try? JSONDecoder().decode(JSONValue.self, from: result.stdoutBytes),
                let items = value.arrayItems
            else { continue }
            let states = Set(items.compactMap { $0["state"]?.stringValue })
            if states.contains("OPEN") {
                byThread[thread] = .open
            } else if states.contains("MERGED") {
                byThread[thread] = .merged
            } else if states.contains("CLOSED") {
                byThread[thread] = .closed
            } else if items.isEmpty {
                byThread[thread] = .absent
            }
        }
        return byThread
    }

    /// The same, for the units a past run made a thread for.
    static func states(units: [String: String], gh: GitRunner?, project: Project) async -> [String: UnitPullRequest] {
        let byThread = await threadStates(threads: Set(units.values), gh: gh, project: project)
        return units.compactMapValues { byThread[$0] }
    }
}
