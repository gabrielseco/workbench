import Foundation

/// The `PATH` a person's own terminal has. An app started from the Dock or Finder gets the system's bare `PATH`, not the one their
/// shell builds in its profile (Homebrew, mise, pnpm, `~/.local/bin`), so `codex`, `claude`, `node` and the project's check command
/// are all "not found" there while they run fine in a terminal. The shell is asked once, with a timeout, through the same short
/// command runner as `git`; anything that goes wrong leaves the `PATH` as it was.
public enum LoginShellPath {
    static let startMarker = "__WORKBENCH_PATH_START__"
    static let endMarker = "__WORKBENCH_PATH_END__"

    /// The `PATH` the login shell builds, followed by whatever of `current` it lacks; `current` when the shell cannot be asked.
    public static func resolve(
        shell: String?, current: String, home: String = NSHomeDirectory(), timeout: TimeInterval = 5
    ) async -> String {
        let path = shell?.isEmpty == false ? shell ?? "" : "/bin/zsh"
        guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else { return current }
        // `-i` too: a PATH that a tool such as mise sets up is usually added by the interactive profile. No terminal, no input.
        let environment = ["HOME": home, "SHELL": path, "TERM": "dumb", "PATH": current]
        let runner = GitRunner(executable: URL(fileURLWithPath: path), environment: environment, timeout: timeout)
        let script = "printf '%s%s%s' '\(startMarker)' \"$PATH\" '\(endMarker)'"
        guard let result = try? await runner.run(["-ilc", script], in: URL(fileURLWithPath: home)), result.succeeded,
            let login = parse(result.stdout)
        else { return current }
        return merge(login: login, current: current)
    }

    /// Takes the text between the markers, so what a profile prints around it (greetings, warnings) is ignored. Only absolute
    /// entries are kept; nil when nothing usable is there.
    static func parse(_ output: String) -> String? {
        guard let start = output.range(of: startMarker),
            let end = output.range(of: endMarker, range: start.upperBound..<output.endIndex)
        else { return nil }
        let entries = output[start.upperBound..<end.lowerBound].split(separator: ":").map(String.init)
            .filter { $0.hasPrefix("/") && !$0.contains("\n") && !$0.contains("\0") }
        return entries.isEmpty ? nil : entries.joined(separator: ":")
    }

    /// The login shell's entries first, then the current ones it lacks, each once: nothing the app had is lost.
    static func merge(login: String, current: String) -> String {
        var seen = Set<String>()
        return (login.split(separator: ":") + current.split(separator: ":")).map(String.init)
            .filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
    }

    /// Replaces this process's `PATH` with the resolved one, so everything that reads it from here on finds the person's tools.
    /// `set` is `setenv` outside tests.
    public static func applyToEnvironment(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        set: (String) -> Void = { setenv("PATH", $0, 1) }
    ) async {
        let current = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let resolved = await resolve(shell: environment["SHELL"], current: current)
        if resolved != current { set(resolved) }
    }
}
