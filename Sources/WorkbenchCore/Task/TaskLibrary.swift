import Foundation

/// A task as it is on disk now.
public struct LoadedTask: Sendable {
    public var definition: TaskDefinition
    public var pendingScript: Data?
    /// The skill text that goes into the prompt.
    public var includeText: Data?
    /// What approval binds to: the settings, the instructions, the script and the included skill.
    public var hash: String
}

/// One line of `task list`.
public struct TaskSummary: Sendable, Equatable {
    public var name: String
    /// Why the task cannot run at all (a file that does not parse, a script that is missing), nil when it loads.
    public var problem: String?
    public var schedule: String?
    public var fix: TaskFix?
    public var approval: TaskApproval.State
    public var nextDue: Date?
    public var lastOutcome: TaskOutcome?
    public var lastRun: Date?
}

/// The tasks of one project.
public struct TaskLibrary: Sendable {
    public let project: Project

    public init(project: Project) { self.project = project }

    /// The names of the folders under `.workbench/tasks` that hold a `task.md`, sorted.
    public func names() -> [String] {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: project.tasksDirectory.path)) ?? []
        return entries.filter {
            SafeNames.isThreadID($0) && FileManager.default.fileExists(atPath: project.taskFileURL($0).path)
        }.sorted()
    }

    public func load(_ name: String) throws -> LoadedTask {
        guard SafeNames.isThreadID(name), FileManager.default.fileExists(atPath: project.taskFileURL(name).path) else {
            throw TaskFileError.notFound(".workbench/tasks/\(name)/task.md")
        }
        let files = TaskFiles(project: project)
        let data = try files.read(".workbench/tasks/\(name)/task.md", limit: TaskFiles.maxTaskFileBytes)
        guard let text = String(data: data, encoding: .utf8) else {
            throw TaskFileError.unreadable(".workbench/tasks/\(name)/task.md")
        }
        let definition = try TaskDefinition.parse(text, name: name)
        let script = try definition.pending.map { try files.read($0, limit: TaskFiles.maxScriptBytes) }
        let include = try definition.include.map { try files.read($0, limit: TaskFiles.maxIncludeBytes) }
        return LoadedTask(
            definition: definition, pendingScript: script, includeText: include,
            hash: TaskApproval.hash(task: definition, pendingScript: script, include: include))
    }

    /// Records that the task, as it is now, may run unattended.
    @discardableResult
    public func approve(_ name: String, now: @escaping @Sendable () -> Date = { Date() }) async throws -> String {
        let loaded = try load(name)
        // A scaffold waiting to be written is not something to run unattended.
        if loaded.definition.instructions.contains(TaskScaffold.placeholder) { throw TaskFileError.placeholder }
        let log = TaskRunLog(project: project, name: name)
        let writer = try await log.openWriter(now: now)
        do {
            try await writer.append(.taskApproved, data: ["hash": .string(loaded.hash)])
        } catch {
            await writer.close()
            throw error
        }
        await writer.close()
        return loaded.hash
    }

    public func summary(_ name: String, now: Date = Date(), calendar: Calendar = .current) -> TaskSummary {
        let history: TaskHistory
        do {
            history = try TaskRunLog(project: project, name: name).history()
        } catch {
            return TaskSummary(
                name: name, problem: "the run log is damaged: \(error)", schedule: nil, fix: nil, approval: .never,
                nextDue: nil, lastOutcome: nil, lastRun: nil)
        }
        do {
            let loaded = try load(name)
            let base = history.scheduleBase
            return TaskSummary(
                name: name, problem: nil, schedule: loaded.definition.schedule?.summary, fix: loaded.definition.fix,
                approval: TaskApproval.state(approvedHash: history.approvedHash, currentHash: loaded.hash),
                nextDue: base.flatMap { loaded.definition.schedule?.nextDue(since: $0, calendar: calendar) },
                lastOutcome: history.lastRun?.outcome, lastRun: history.lastRun?.started)
        } catch {
            return TaskSummary(
                name: name, problem: "\(error)", schedule: nil, fix: nil, approval: .never, nextDue: nil,
                lastOutcome: history.lastRun?.outcome, lastRun: history.lastRun?.started)
        }
    }
}
