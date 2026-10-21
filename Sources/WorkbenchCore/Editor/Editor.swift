import Foundation

/// Where the editor `workbench open` uses came from, in the order it is looked for.
public enum EditorSource: String, Sendable, Equatable {
    case flag = "--editor"
    case project
    case global
}

/// The `editor` setting `open` resolved: its text and where it was found.
public struct EditorChoice: Sendable, Equatable {
    public var value: String
    public var source: EditorSource

    public init(value: String, source: EditorSource) {
        self.value = value
        self.source = source
    }

    /// `--editor`, else the project's `editor`, else the global one; nil when none is set. Never `$EDITOR` or
    /// `$VISUAL`: a terminal editor started with no terminal would block.
    public static func resolve(flag: String?, project: String?, global: String?) -> EditorChoice? {
        if let flag { return EditorChoice(value: flag, source: .flag) }
        if let project { return EditorChoice(value: project, source: .project) }
        if let global { return EditorChoice(value: global, source: .global) }
        return nil
    }
}

/// What `open` runs: the executable (an absolute path) and its arguments, the worktree path last.
public struct EditorCommand: Sendable, Equatable {
    public var executable: String
    public var arguments: [String]

    /// The command line as one readable string, for messages.
    public var display: String { ([executable] + arguments).joined(separator: " ") }
}

public enum EditorError: Error, Equatable, Sendable, CustomStringConvertible {
    case notSet
    case noWorktree(id: String, path: String)
    case outsideWorktrees(path: String, resolved: String)
    case notFound(editor: String, tried: [String])
    case launchFailed(editor: String, reason: String)
    case timedOut(editor: String, seconds: Int)
    case failed(editor: String, how: String, lastLine: String?)

    public var description: String {
        switch self {
        case .notSet:
            "no editor set: pass --editor <name-or-command>, set `editor` in .workbench/config.toml or "
                + "~/.workbench/config.toml, or use --print to get the path"
        case .noWorktree(let id, let path):
            "thread \(id) has no worktree at \(path) (it was shipped, accepted, discarded or abandoned, or has not run yet)"
        case .outsideWorktrees(let path, let resolved):
            "\(path) resolves to \(resolved), which is outside .workbench/worktrees/; not opening it"
        case .notFound(let editor, let tried):
            "cannot start editor '\(editor)': tried \(tried.joined(separator: ", then "))"
        case .launchFailed(let editor, let reason): "cannot start editor '\(editor)': \(reason)"
        case .timedOut(let editor, let seconds):
            "editor '\(editor)' did not return within \(seconds)s; it was stopped"
        case .failed(let editor, let how, let lastLine):
            "editor '\(editor)' \(how)" + (lastLine.map { ": \($0)" } ?? "")
        }
    }
}

/// The `editor` key and how its value becomes a command. Personal and machine-level: only `open` reads it, so it can
/// never change what a run does.
public enum Editor {
    /// The known short names, each with its launcher on PATH and its macOS app for `open -a`.
    public static let known: [(name: String, app: String)] = [
        ("cursor", "Cursor"), ("code", "Visual Studio Code"), ("zed", "Zed"), ("subl", "Sublime Text"),
        ("windsurf", "Windsurf"),
    ]

    public static let macOpen = "/usr/bin/open"

    #if os(macOS)
        public static let isMacOS = true
    #else
        public static let isMacOS = false
    #endif

    static func app(for name: String) -> String? { known.first { $0.name == name }?.app }

    /// Why a value cannot be used, nil when it can. A known name, or one plain command like `check_command`; a path
    /// must be absolute, since a relative one would be looked up in the worktree a run wrote.
    public static func valueProblem(_ value: String) -> String? {
        if app(for: value) != nil { return nil }
        if let reason = Config.checkCommandProblem(value) { return reason }
        let first = value.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? ""
        if first.contains("/"), !first.hasPrefix("/") {
            return "must be a known editor (\(known.map(\.name).joined(separator: ", "))), a command on PATH or an absolute path"
        }
        return nil
    }

    /// Where macOS keeps the apps a person installs, which `open -a` looks in.
    public static func defaultApplicationDirectories(home: String = NSHomeDirectory()) -> [String] {
        ["/Applications", "\(home)/Applications", "/System/Applications"]
    }

    /// The command for `value` opening `path`, or `.notFound` naming what was tried. Pure: nothing is run, so the
    /// macOS fallback can be checked as data.
    public static func command(
        for value: String, path: String, searchPath: String?, isMacOS: Bool, openExecutable: String = macOpen,
        applicationDirectories: [String] = defaultApplicationDirectories()
    ) throws -> EditorCommand {
        // Bare names are looked up on PATH's absolute entries only: `.` would let the worktree stand in for one.
        let absolutePath = (searchPath ?? "").split(separator: ":").filter { $0.hasPrefix("/") }.joined(separator: ":")
        if let app = app(for: value) {
            if let launcher = ExecutableResolver.resolve(value, searchPath: absolutePath) {
                return EditorCommand(executable: launcher.path, arguments: [path])
            }
            var tried = ["'\(value)' on PATH"]
            if isMacOS {
                if !FileManager.default.isExecutableFile(atPath: openExecutable) {
                    tried.append("\(openExecutable) -a \"\(app)\"")
                } else if applicationDirectories.contains(where: {
                    FileManager.default.fileExists(atPath: "\($0)/\(app).app")
                }) {
                    return EditorCommand(executable: openExecutable, arguments: ["-a", app, path])
                } else {
                    // `open -a` would only fail with a message of its own: say what was looked for.
                    tried.append("\(app).app in \(applicationDirectories.joined(separator: ", "))")
                }
            }
            throw EditorError.notFound(editor: value, tried: tried)
        }
        // Validated already: no quotes or operators, so the words are just words.
        let words = value.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let name = words.first, let executable = ExecutableResolver.resolve(name, searchPath: absolutePath) else {
            let name = words.first ?? value
            throw EditorError.notFound(editor: value, tried: [name.contains("/") ? name : "'\(name)' on PATH"])
        }
        return EditorCommand(executable: executable.path, arguments: Array(words.dropFirst()) + [path])
    }

    /// The thread's worktree, checked to exist and to be inside `.workbench/worktrees/` once symlinks are resolved.
    public static func worktree(project: Project, threadID: String) throws -> URL {
        let root = project.worktreesDirectory
        let path = root.appendingPathComponent(threadID)
        guard SafeNames.isThreadID(threadID) else { throw EditorError.noWorktree(id: threadID, path: path.path) }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw EditorError.noWorktree(id: threadID, path: path.path)
        }
        let resolved = path.resolvingSymlinksInPath().standardizedFileURL.path
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolved.hasPrefix(base + "/"), !resolved.dropFirst(base.count + 1).contains("/") else {
            throw EditorError.outsideWorktrees(path: path.path, resolved: resolved)
        }
        return URL(fileURLWithPath: resolved, isDirectory: true)
    }

    /// The fixed environment the launcher gets: enough to find and start an app, no tokens or project variables.
    static let environmentNames: Set<String> = ["PATH", "HOME", "USER", "LOGNAME", "SHELL", "LANG", "TMPDIR"]

    public static func environment(from parent: [String: String]) -> [String: String] {
        parent.filter { environmentNames.contains($0.key) || $0.key.hasPrefix("LC_") }
    }
}
