import Foundation

extension ThreadService {
    /// Applies one edit to the thread's goal file and writes it back, atomically. A draft is free to edit; an approved goal
    /// goes back to `stale` when the edit touches what the approval binds (the hash decides, not this function), so it is
    /// approved again. Refused, with nothing written, when the thread has ended or a turn is running, or when the edit would
    /// leave a goal that does not parse.
    @discardableResult
    public func editGoal(id: String, _ edit: GoalEdit) async throws -> GoalFile {
        guard SafeNames.isThreadID(id) else { throw ThreadStoreError.invalidName(id) }
        return try await withLog(id) { log in
            let state = ThreadStore(project: project).state(of: id)
            if let decision = state.decision { throw ThreadServiceError.threadEnded(decision) }
            if let pid = runnerPID(id: id) { throw ThreadServiceError.running(pid: pid) }
            let url = project.goalURL(id)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                throw ThreadServiceError.goalMissing(url.path)
            }
            let file: GoalFile
            do { file = try GoalFile.parse(text) } catch let error as GoalParseError {
                throw ThreadServiceError.goalInvalid(error.description)
            }
            let edited: GoalFile
            do { edited = try GoalEditor.apply(edit, to: file) } catch let error as GoalEditError {
                throw ThreadServiceError.goalEditRefused(error.reason)
            }
            try edited.text.write(to: url, atomically: true, encoding: .utf8)
            let goal = edited.goal
            let saved: JSONValue = ["status": .string(goal.status.rawValue), "hash": .string(goal.contentHash)]
            try await log.append(.goalSaved, data: saved)
            return edited
        }
    }

    /// The config `approve` uses (the one given, else the project's), after checking the goal's `skip` against it: a name that
    /// is no step would be ignored for ever and look like a switch that works.
    func configChecked(_ given: Config?, against goal: Goal) throws -> Config? {
        let config = given ?? (try? Config.load(from: project.configURL))
        let steps = ["verifier", "judge"] + (config?.review.stages ?? ReviewConfig.defaultStages)
        if let name = goal.skip.first(where: { !steps.contains($0) }) {
            let why = "which is not a step: use verifier, judge or a stage in [review] stages"
            throw ThreadServiceError.goalInvalid("'skip' names '\(name)', \(why)")
        }
        // The goal's folders must hold now, so the person hears it at approval and not at the first turn.
        if case .failure(let problem) = ReadAlso.resolve(goal.readAlso, projectRoot: project.root) {
            throw ThreadServiceError.goalInvalid("\(problem)")
        }
        // The project's own folders are the run's to report; here they only count against the limit.
        let together = ReadAlso.resolve(config: config?.readAlso ?? [], goal: goal.readAlso, projectRoot: project.root)
        if case .failure(let problem) = together, problem.entry == "read_also" {
            throw ThreadServiceError.goalInvalid("\(problem)")
        }
        return config
    }
}
