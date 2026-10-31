import Foundation

public enum TaskScaffoldError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidName(String)
    case exists(String)
    case unsafePath(key: String, path: String)
    case cannotWrite(String)

    public var description: String {
        switch self {
        case .invalidName(let name): "'\(name)' is not a usable task name: letters, digits, '.', '_' and '-' only."
        case .exists(let path): "\(path) exists already; nothing was changed."
        case .unsafePath(let key, let path): "'\(path)' is not a path inside the project (for \(key))."
        case .cannotWrite(let why): "the task could not be written: \(why)"
        }
    }
}

/// What `task new` made.
public struct TaskScaffoldResult: Sendable, Equatable {
    public var directory: URL
    /// Paths named for `include` or `inputs` that do not exist yet: approving the task refuses them until they do.
    public var missing: [String]
}

/// The first files of a task, ready to edit: every key of `task.md` there and explained, the safe default (`fix: report`), and a
/// `pending` script that lists nothing. Free: no agent runs.
public enum TaskScaffold {
    /// Written into the instructions, and refused by `task approve` until a person replaced it.
    public static let placeholder = "TODO(workbench)"
    static let scriptName = "pending.sh"

    public static func create(
        project: Project, name: String, include: String? = nil, inputs: [String] = []
    ) throws -> TaskScaffoldResult {
        guard SafeNames.isThreadID(name) else { throw TaskScaffoldError.invalidName(name) }
        if let include, !TaskDefinition.isSafeRelativePath(include) || include.hasSuffix("/") {
            throw TaskScaffoldError.unsafePath(key: "include", path: include)
        }
        for input in inputs where !TaskDefinition.isSafeRelativePath(input) {
            throw TaskScaffoldError.unsafePath(key: "inputs", path: input)
        }
        if inputs.count > TaskDefinition.maxInputs {
            throw TaskScaffoldError.unsafePath(key: "inputs", path: "more than \(TaskDefinition.maxInputs) paths")
        }
        let directory = project.taskDirectory(name)
        guard !FileManager.default.fileExists(atPath: directory.path) else {
            throw TaskScaffoldError.exists(".workbench/tasks/\(name)")
        }
        let script = ".workbench/tasks/\(name)/\(scriptName)"
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try taskFile(name: name, script: script, include: include, inputs: inputs)
                .write(to: project.taskFileURL(name), atomically: true, encoding: .utf8)
            let scriptURL = directory.appendingPathComponent(scriptName)
            try scriptText.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        } catch {
            // Only the folder this call made goes: it did not exist before.
            try? FileManager.default.removeItem(at: directory)
            throw TaskScaffoldError.cannotWrite("\(error)")
        }
        let files = TaskFiles(project: project)
        let missing = ([include].compactMap { $0 } + inputs).filter { (try? files.resolve($0)) == nil }
        return TaskScaffoldResult(directory: directory, missing: missing)
    }

    static func taskFile(name: String, script: String, include: String?, inputs: [String]) -> String {
        let includeLine =
            include.map { "include: \($0)" }
            ?? "# include: .claude/skills/<skill>/SKILL.md   # a skill whose text goes into the prompt (up to 16 KiB)"
        let inputsLine =
            inputs.isEmpty
            ? "# inputs: [list.txt]   # files or directories the agent reads, any format (up to 32 KiB in all)"
            : "inputs: [\(inputs.joined(separator: ", "))]"
        return """
            ---
            # When it runs. A task with neither is run by hand only (workbench task run \(name)).
            # at: 04:00             # a time of day...
            # days: weekdays        # ...on these days: daily | weekdays | mon,wed,fri
            # every: 1h             # or an interval, 5m to 30d (not together with at)
            batch: 1                # units of work one run takes, 1 to 20
            \(includeLine)
            \(inputsLine)
            pending: \(script)
            fix: report             # report: only lists what it would take. pr: does the work and opens the pull request
            # budget: 3.00          # USD for the coding turns of one run
            ---
            \(placeholder): say what each run should do, as you would to a colleague. If a skill is included, say to follow it.
            Delete this line when you have.

            """
    }

    static let scriptText = """
        #!/bin/sh
        # Prints the units of work still to do, as JSON, in the order to work through them:
        #   [{"id": "ROU", "title": "Romania v1 -> v6"}, {"id": "TUR"}]
        # An id is letters, digits, '.', '_' or '-'. Print [] when there is nothing to do.
        # It runs from the project root with a plain environment, for 60 seconds at most, and it is part of what you approve.
        echo '[]'

        """
}
