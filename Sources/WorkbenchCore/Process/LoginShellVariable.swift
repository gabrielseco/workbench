import Foundation

/// The gateway key for a process that no terminal started: an app opened from the Dock, or a timer under launchd, has none of what the
/// person's shell exports. As for `LoginShellPath`, the login shell is asked once, with a timeout, and only for the one variable the
/// project's config names; a variable the process already has is never replaced, and anything that goes wrong leaves it unset, so the
/// run is refused by name as it would be. The value is kept in this process's environment only: it is not logged, and the shell's
/// output is read through a pipe, never through `GitRunner`'s temporary files (a killed process would leave the key on disk).
public enum LoginShellVariable {
    static let startMarker = "__WORKBENCH_VALUE_START__"
    static let endMarker = "__WORKBENCH_VALUE_END__"
    /// A longer value is not a key.
    static let maxLength = 4096

    /// The value of `name` as an interactive login shell has it; nil when the name is not one, the shell cannot be asked, or the
    /// variable is empty there.
    public static func resolve(
        _ name: String, shell: String?, home: String = NSHomeDirectory(), path: String, timeout: TimeInterval = 10
    ) async -> String? {
        // The name goes into a script: only what a variable name can be.
        guard name.range(of: #"^[A-Z][A-Z0-9_]{0,63}\z"#, options: .regularExpression) != nil else { return nil }
        let program = shell?.isEmpty == false ? shell ?? "" : "/bin/zsh"
        guard program.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: program) else { return nil }
        let environment = ["HOME": home, "SHELL": program, "TERM": "dumb", "PATH": path]
        let script = "printf '%s%s%s\\n' '\(startMarker)' \"$\(name)\" '\(endMarker)'"
        var spawn = SpawnRequest(
            executable: URL(fileURLWithPath: program), arguments: ["-ilc", script], environment: environment,
            workingDirectory: URL(fileURLWithPath: home), timeout: timeout)
        spawn.killGrace = 1
        // Room for a talkative profile; the value's line is far shorter.
        spawn.maxLineBytes = 64 * 1024
        spawn.maxOutputBytes = 1 << 20
        guard let run = try? ProcessRunner.start(spawn) else { return nil }
        var found: String?
        var exit: ProcessExit?
        for await event in run.events {
            switch event {
            case .line(let line): found = parse(line) ?? found
            case .exited(let ended): exit = ended
            case .started, .oversizedLine: break
            }
        }
        // A shell that failed or ran out of time is not believed, whatever it printed first.
        guard let exit, exit.cause == .natural, exit.termination == .exited(0) else { return nil }
        return found
    }

    /// The text between the markers, so what a profile prints around it is ignored; nil when it is empty, too long, or holds a control
    /// character.
    static func parse(_ output: String) -> String? {
        guard let start = output.range(of: startMarker),
            let end = output.range(of: endMarker, range: start.upperBound..<output.endIndex)
        else { return nil }
        let value = String(output[start.upperBound..<end.lowerBound])
        let clean = !value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
        return !value.isEmpty && value.utf8.count <= maxLength && clean ? value : nil
    }

    /// Gives this process the OpenCode gateway key of `project` when its config names one and the process has none. `set` is `setenv`
    /// outside tests.
    public static func fillGatewayKey(
        project: Project, environment: [String: String] = ProcessInfo.processInfo.environment,
        set: (String, String) -> Void = { setenv($0, $1, 1) }
    ) async {
        guard let name = (try? Config.load(from: project.configURL))?.agents.opencode?.apiKeyVariable,
            environment[name]?.isEmpty != false,
            let value = await resolve(
                name, shell: environment["SHELL"], home: environment["HOME"] ?? NSHomeDirectory(),
                path: environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        else { return }
        set(name, value)
    }
}
