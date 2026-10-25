import Foundation

@testable import WorkbenchCore

/// A git that writes each call (directory and arguments) to a file, then runs the real one.
struct CountingGit {
    let runner: GitRunner
    let log: URL

    init(wrapping real: GitRunner) throws {
        log = Scratch.url("gitcalls").appendingPathExtension("txt")
        let script = Scratch.url("gitcount").appendingPathExtension("sh")
        try "#!/bin/sh\necho \"$PWD :: $*\" >> \(log.path)\nexec \(real.executable.path) \"$@\"\n"
            .write(to: script, atomically: true, encoding: .utf8)
        chmod(script.path, 0o755)
        runner = GitRunner(executable: script, environment: real.environment)
    }

    var calls: [String] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }
}
