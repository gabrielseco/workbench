import Foundation

/// One unit of work a task's `pending` script named: the thing a run does once (a country to bump, a file to migrate).
public struct TaskUnit: Sendable, Equatable {
    /// Safe to use in a branch name and a path (`SafeNames`).
    public var id: String
    public var title: String
}

public enum PendingScriptError: Error, Equatable, Sendable, CustomStringConvertible {
    case notExecutable(String)
    case launchFailed(String)
    case timedOut(seconds: Int)
    case failed(exit: Int32, stderr: String)
    case outputTooLarge
    case malformed(String)

    public var description: String {
        switch self {
        case .notExecutable(let path): "the pending script '\(path)' is not executable (chmod +x)"
        case .launchFailed(let why): "the pending script did not start: \(why)"
        case .timedOut(let seconds): "the pending script did not finish in \(seconds) s"
        case .failed(let code, let stderr): "the pending script exited with \(code): \(stderr)"
        case .outputTooLarge: "the pending script printed too much"
        case .malformed(let why): "the pending script's output is not a list of units: \(why)"
        }
    }
}

/// What became of the pull request a unit has, as the caller found it with `gh`.
public enum UnitPullRequest: Sendable, Equatable {
    case open
    case merged
    /// Closed without merging: the work was not taken, so the unit is offered again.
    case closed
    /// GitHub answered and the branch has no pull request at all.
    case absent
}

public enum PendingUnits {
    public static let timeout: TimeInterval = 60
    public static let maxUnits = 500
    public static let maxTitleLength = 200

    /// Runs the task's `pending` script from the project root and parses what it prints: a JSON list of
    /// `{"id": ..., "title": ...}` in the order it should be worked through. The output is untrusted: ids go through
    /// `SafeNames` before they reach a branch name or a path, and a duplicate or an unusable one refuses the whole list.
    public static func run(
        script relative: String, project: Project, environment: [String: String] = ProcessInfo.processInfo.environment,
        timeout: TimeInterval = timeout, expiry: CommandExpiry? = nil
    ) async throws -> [TaskUnit] {
        let url = try TaskFiles(project: project).resolve(relative)
        guard FileManager.default.isExecutableFile(atPath: url.path) else { throw PendingScriptError.notExecutable(relative) }
        let keep = ["PATH", "HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "SSH_AUTH_SOCK"]
        var env = environment.filter { keep.contains($0.key) || $0.key.hasPrefix("LC_") }
        env["WORKBENCH_TASK_PROJECT"] = project.root.path
        let runner = GitRunner(executable: url, environment: env, timeout: timeout, expiry: expiry)
        let result: GitResult
        do {
            result = try await runner.run([], in: project.root)
        } catch GitError.timedOut {
            throw PendingScriptError.timedOut(seconds: Int(timeout))
        } catch {
            throw PendingScriptError.launchFailed("\(error)")
        }
        guard !result.outputTruncated else { throw PendingScriptError.outputTooLarge }
        guard result.succeeded else {
            throw PendingScriptError.failed(exit: result.status, stderr: String(result.stderr.suffix(500)))
        }
        return try parse(result.stdoutBytes)
    }

    static func parse(_ data: Data) throws -> [TaskUnit] {
        let value: JSONValue
        do { value = try JSONDecoder().decode(JSONValue.self, from: data) } catch {
            throw PendingScriptError.malformed("not JSON")
        }
        guard let items = value.arrayItems else { throw PendingScriptError.malformed("expected a JSON list") }
        guard items.count <= maxUnits else { throw PendingScriptError.malformed("more than \(maxUnits) units") }
        var seen = Set<String>()
        var units: [TaskUnit] = []
        for item in items {
            guard let id = item["id"]?.stringValue, SafeNames.isThreadID(id) else {
                throw PendingScriptError.malformed("every unit needs an 'id' of letters, digits, '.', '_' or '-'")
            }
            guard seen.insert(id).inserted else { throw PendingScriptError.malformed("'\(id)' is listed twice") }
            let title = (item["title"]?.stringValue ?? id).unicodeScalars.filter { $0.value >= 32 }
            units.append(TaskUnit(id: id, title: String(String.UnicodeScalarView(title).prefix(maxTitleLength))))
        }
        return units
    }

    /// The units a run should take now: the script's order, minus what is already done, at most `batch`.
    ///
    /// A unit is left out when its pull request is open or merged. A unit a past run opened a pull request for, whose
    /// state could not be found out (`gh` was unreachable), is left out too: doing the work twice is worse than
    /// waiting a day. Only a pull request closed unmerged brings a unit back.
    public static func select(
        units: [TaskUnit], history: TaskHistory, pullRequests: [String: UnitPullRequest], batch: Int
    ) -> [TaskUnit] {
        let recorded = history.unitsWithThreads
        let pending = units.filter { unit in
            switch pullRequests[unit.id] {
            case .open, .merged: false
            case .closed: true
            case .absent: !history.openedUnits.contains(unit.id)
            case nil: recorded[unit.id] == nil
            }
        }
        return Array(pending.prefix(batch))
    }
}
