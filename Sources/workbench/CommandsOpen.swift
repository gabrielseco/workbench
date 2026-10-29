import Foundation
import WorkbenchCore

extension Commands {
    /// `open [id] [--editor <name-or-command>] [--print] [--goal | --diff]`: the thread's worktree in an editor, or its
    /// path; with `--goal` its goal file, which a draft has before any worktree exists; with `--diff` a folder where
    /// the thread's changes are uncommitted work, so the editor lists every changed file (`ReviewWorkspace`). Writes no
    /// event and changes nothing in the thread or the worktree.
    static func open(_ args: [String]) async throws {
        var a = Arguments(args)
        let flag = try a.value("--editor")
        let printOnly = a.flag("--print")
        let goal = a.flag("--goal")
        let diff = a.flag("--diff")
        let named = a.positional()
        try a.requireEmpty()
        if flag != nil, printOnly { throw CLIError.usage("--editor and --print do not go together") }
        if goal, diff { throw CLIError.usage("--goal and --diff do not go together") }
        if let flag, let reason = Editor.valueProblem(flag) { throw CLIError.usage("--editor \(reason)") }

        let ctx = try await Context.load()
        let id = try ctx.threadID(named)
        let path: URL
        var workspace: ReviewWorkspace.Built?
        do {
            if goal {
                path = try Editor.goalFile(project: ctx.project, threadID: id)
            } else if diff {
                let built = try await ReviewWorkspace.prepare(project: ctx.project, threadID: id, git: try GitRunner.discover())
                workspace = built
                path = built.path
            } else {
                path = try Editor.worktree(project: ctx.project, threadID: id)
            }
        } catch let error as EditorError {
            switch error {
            case .launchFailed: throw CLIError.message("\(error)")
            default: throw CLIError.refused("\(error)")
            }
        }
        if let workspace { noteWorkspace(workspace) }
        if printOnly { return out(path.path) }

        let environment = ProcessInfo.processInfo.environment
        guard let choice = try editorChoice(flag: flag, project: ctx.project, environment: environment) else {
            throw CLIError.refused("\(EditorError.notSet)")
        }
        do {
            let command = try Editor.command(
                for: choice.value, path: path.path, searchPath: environment["PATH"], isMacOS: Editor.isMacOS)
            try await EditorLauncher.launch(
                command, editor: choice.value, in: goal ? path.deletingLastPathComponent() : path,
                environment: Editor.environment(from: environment))
        } catch let error as EditorError {
            switch error {
            case .notFound: throw CLIError.refused("\(error)")
            default: throw CLIError.message("\(error)")
            }
        }
        out("opened \(path.path) in \(choice.value)")
    }

    /// What the workspace holds, on stderr so `--print` still prints only the path.
    private static func noteWorkspace(_ built: ReviewWorkspace.Built) {
        let line = "\(built.changed) changed file(s) as uncommitted work; edits here do not go back to the thread"
        FileHandle.standardError.write(Data((line + "\n").utf8))
        if !built.skipped.isEmpty {
            let skipped = "left out (not a plain file, or over \(ReviewWorkspace.sizeLimit >> 20) MB): "
                + built.skipped.prefix(10).joined(separator: ", ") + (built.skipped.count > 10 ? ", …" : "")
            FileHandle.standardError.write(Data((skipped + "\n").utf8))
        }
    }

    /// `--editor`, else the project's `editor`, else the global one. A config is read only when it is the one asked.
    static func editorChoice(flag: String?, project: Project, environment: [String: String]) throws -> EditorChoice? {
        if let flag { return EditorChoice(value: flag, source: .flag) }
        var projectEditor: String?
        do { projectEditor = try Config.load(from: project.configURL).editor } catch let error as ConfigError {
            // A repository with no config has no project editor; any other problem is the config's to fix.
            guard error.problems.map(\.code) == [.notFound] else { throw error }
        }
        if projectEditor != nil { return EditorChoice.resolve(flag: nil, project: projectEditor, global: nil) }
        let global = try GlobalConfig.load(from: GlobalConfig.defaultURL(environment: environment)).editor
        return EditorChoice.resolve(flag: nil, project: nil, global: global)
    }

    static func printEditor(_ choice: EditorChoice?, problem: String?) {
        if let choice {
            out("editor:  \(choice.value) (from \(choice.source.rawValue))")
        } else if let problem {
            out("editor:  none set (\(problem))")
        } else {
            out("editor:  none set")
        }
    }
}
