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

    /// How many open pull requests one question may return. A repository with more than this cannot be counted from one answer.
    static let openListLimit = 500

    /// The head branches of every open pull request of the repository, in one question: how a task counts its own, without asking
    /// about each earlier thread. A failure when it cannot be known (`gh` missing or failing, or the list is as long as the limit and
    /// may be cut), and the failure says why, so a person can tell a dropped connection from a missing login.
    static func openBranches(gh: GitRunner?, project: Project) async -> Result<Set<String>, OpenListFailure> {
        guard let gh else { return .failure(OpenListFailure("GitHub's command line tool (gh) was not found")) }
        let result: GitResult
        do {
            result = try await gh.run(
                ["pr", "list", "--state", "open", "--json", "headRefName", "--limit", "\(openListLimit)"], in: project.root)
        } catch GitError.timedOut(_, let seconds) {
            return .failure(OpenListFailure("gh did not answer in \(Int(seconds)) s; is there an internet connection?"))
        } catch {
            return .failure(OpenListFailure("gh could not be run: \(error)"))
        }
        guard result.succeeded else {
            return .failure(OpenListFailure(failedReason(status: result.status, stderr: result.stderr)))
        }
        guard !result.outputTruncated,
            let value = try? JSONDecoder().decode(JSONValue.self, from: result.stdoutBytes),
            let items = value.arrayItems
        else { return .failure(OpenListFailure("gh's answer was cut off or was not a list")) }
        guard items.count < openListLimit else {
            return .failure(OpenListFailure("\(openListLimit) or more pull requests are open, so the list may be cut"))
        }
        return .success(Set(items.compactMap { $0["headRefName"]?.stringValue }))
    }

    /// Why a `gh` that exited non-zero failed: its own first line of complaint, bounded, with a hint when it reads like no network.
    static func failedReason(status: Int32, stderr: String) -> String {
        let line = stderr.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let printable = String.UnicodeScalarView(line.unicodeScalars.filter { $0.value >= 32 && $0.value != 127 })
        let clean = String(printable.prefix(200)).trimmingCharacters(in: .whitespaces)
        let lower = stderr.lowercased()
        let offline = [
            "error connecting", "no such host", "could not resolve", "network is unreachable", "dial tcp", "i/o timeout",
            "connection refused", "connection reset", "tls handshake", "offline",
        ].contains { lower.contains($0) }
        var why = "gh exited with status \(status)"
        if !clean.isEmpty { why += ": " + clean }
        if offline { why += " (looks like no internet connection)" }
        return why
    }

    /// Why the list of open pull requests could not be had, in words for the run log.
    struct OpenListFailure: Error, Equatable, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    /// The same, for the units a past run made a thread for.
    static func states(units: [String: String], gh: GitRunner?, project: Project) async -> [String: UnitPullRequest] {
        let byThread = await threadStates(threads: Set(units.values), gh: gh, project: project)
        return units.compactMapValues { byThread[$0] }
    }
}
