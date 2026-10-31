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
        try self.init(in: Project(root: try Scratch.directory("task-project")), name: name, front: front, body: body)
    }

    /// A task in a project that already exists (a `RunnerFixture`'s, with a real repository and a fake claude).
    init(
        in project: Project, name: String = "bump", front: String = "at: 04:00\ndays: weekdays\nfix: pr",
        body: String = "Bump the next countries."
    ) throws {
        self.name = name
        self.project = project
        try FileManager.default.createDirectory(at: project.taskDirectory(name), withIntermediateDirectories: true)
        try write(task: "---\n\(front)\n---\n\(body)\n")
    }

    /// A `pending` script that lists these ids, and the front matter line that names it.
    @discardableResult
    func script(_ body: String, as file: String = "pending.sh") throws -> String {
        try write(file, "#!/bin/sh\n\(body)\n")
        let path = project.root.appendingPathComponent(file).path
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return file
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
