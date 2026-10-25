import Foundation

@testable import WorkbenchCore

/// A git that writes each call (directory and arguments) to a file, then runs the real one.
/// Runs the script once on creation, so a script that cannot be started fails here with the launch error, not later
/// as a git call that found nothing and left no line in the log.
struct CountingGit {
    let runner: GitRunner
    let log: URL

    init(wrapping real: GitRunner) async throws {
        log = Scratch.url("gitcalls").appendingPathExtension("txt")
        let script = Scratch.url("gitcount").appendingPathExtension("sh")
        try "#!/bin/sh\necho \"$PWD :: $*\" >> \(log.path)\nexec \(real.executable.path) \"$@\"\n"
            .write(to: script, atomically: true, encoding: .utf8)
        chmod(script.path, 0o755)
        runner = GitRunner(executable: script, environment: real.environment)
        _ = try await runner.run(["--version"], in: log.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: log)
    }

    var calls: [String] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }
}
