import Foundation

/// How much work a task has waiting, as `task list --pending` tells it.
public enum TaskPendingCount: Sendable, Equatable {
    /// The task has no `pending` script: it has one unit, the run itself.
    case noScript
    /// The script is not run: it is part of what approval binds, and an unapproved or edited one has not been approved to run.
    case notRun(why: String)
    /// `waiting` of the `listed` units are left to do (the rest have a pull request open or merged, or are held back).
    case count(waiting: Int, listed: Int)
    /// The script failed, or was not executable: the reason, in one line.
    case failed(String)

    public var text: String {
        switch self {
        case .noScript: "no pending list"
        case .notRun(let why): "not checked (\(why))"
        case .count(let waiting, let listed): "\(waiting) of \(listed)"
        case .failed(let why): "unknown (\(TaskExplanation.clean(why, limit: 120)))"
        }
    }
}

public enum TaskPending {
    /// Runs the task's pending script and works out how many of its units a run would still take, by the same rule a run uses
    /// (`PendingUnits.select`) without the batch limit: units whose pull request is open or merged, or that a past run recorded, do not count.
    /// Only an approved task's script is run: the one on disk now is what was approved.
    public static func count(
        name: String, project: Project, gh: GitRunner?, environment: [String: String] = ProcessInfo.processInfo.environment
    ) async -> TaskPendingCount {
        let library = TaskLibrary(project: project)
        let loaded: LoadedTask
        do { loaded = try library.load(name) } catch { return .failed("\(error)") }
        guard let script = loaded.definition.pending else { return .noScript }
        let history: TaskHistory
        do { history = try TaskRunLog(project: project, name: name).history() } catch { return .failed("the run log is damaged") }
        switch TaskApproval.state(approvedHash: history.approvedHash, currentHash: loaded.hash) {
        case .approved: break
        case .stale: return .notRun(why: "edited since it was approved")
        case .never: return .notRun(why: "not approved")
        }
        let all: [TaskUnit]
        do { all = try await PendingUnits.run(script: script, project: project, environment: environment) } catch {
            return .failed("\(error)")
        }
        let states = await TaskPullRequests.states(units: history.unitsWithThreads, gh: gh, project: project)
        let waiting = PendingUnits.select(units: all, history: history, pullRequests: states, batch: all.count)
        return .count(waiting: waiting.count, listed: all.count)
    }
}
