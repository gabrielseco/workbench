import Foundation

/// Where a project keeps its scheduled tasks (docs/spec/tasks.md):
///
///     <repo>/.workbench/tasks/<name>/task.md, runs.jsonl, and the files the task points at
extension Project {
    public var tasksDirectory: URL { workbenchDirectory.appendingPathComponent("tasks") }

    public func taskDirectory(_ name: String) -> URL { tasksDirectory.appendingPathComponent(name) }
    public func taskFileURL(_ name: String) -> URL { taskDirectory(name).appendingPathComponent("task.md") }
    public func taskRunsURL(_ name: String) -> URL { taskDirectory(name).appendingPathComponent("runs.jsonl") }
}
