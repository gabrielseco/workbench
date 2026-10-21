import Foundation
import WorkbenchCore

extension Commands {
    /// `open [id] [--editor <name-or-command>] [--print]`: the thread's worktree in an editor, or its path. Writes no
    /// event and changes nothing in the thread or the worktree.
    static func open(_ args: [String]) async throws {
        var a = Arguments(args)
        let flag = try a.value("--editor")
        let printOnly = a.flag("--print")
        let named = a.positional()
        try a.requireEmpty()
        if flag != nil, printOnly { throw CLIError.usage("--editor and --print do not go together") }
        if let flag, let reason = Editor.valueProblem(flag) { throw CLIError.usage("--editor \(reason)") }

        let ctx = try await Context.load()
        let id = try ctx.threadID(named)
        let path: URL
        do { path = try Editor.worktree(project: ctx.project, threadID: id) } catch let error as EditorError {
            throw CLIError.refused("\(error)")
        }
        if printOnly { return out(path.path) }

        let environment = ProcessInfo.processInfo.environment
        guard let choice = try editorChoice(flag: flag, project: ctx.project, environment: environment) else {
            throw CLIError.refused("\(EditorError.notSet)")
        }
        do {
            let command = try Editor.command(
                for: choice.value, path: path.path, searchPath: environment["PATH"], isMacOS: Editor.isMacOS)
            try await EditorLauncher.launch(
                command, editor: choice.value, in: path, environment: Editor.environment(from: environment))
        } catch let error as EditorError {
            switch error {
            case .notFound: throw CLIError.refused("\(error)")
            default: throw CLIError.message("\(error)")
            }
        }
        out("opened \(path.path) in \(choice.value)")
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
