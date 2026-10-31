import Foundation

@testable import WorkbenchCore

/// A project directory (no git needed) with a task in it.
struct TaskFixture {
    let project: Project
    let name: String

    init(
        name: String = "bump", front: String = "at: 04:00\ndays: weekdays\nfix: pr",
        body: String = "Bump the next countries."
    ) throws {
        self.name = name
        let root = try Scratch.directory("task-project")
        project = Project(root: root)
        try FileManager.default.createDirectory(at: project.taskDirectory(name), withIntermediateDirectories: true)
        try write(task: "---\n\(front)\n---\n\(body)\n")
    }

    var library: TaskLibrary { TaskLibrary(project: project) }
    var log: TaskRunLog { TaskRunLog(project: project, name: name) }

    func write(task text: String) throws {
        try text.write(to: project.taskFileURL(name), atomically: true, encoding: .utf8)
    }

    func write(_ relative: String, _ text: String) throws {
        let url = project.root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}
