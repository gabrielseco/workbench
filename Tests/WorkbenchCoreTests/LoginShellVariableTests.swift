import Foundation
import Testing

@testable import WorkbenchCore

private let startMark = LoginShellVariable.startMarker
private let endMark = LoginShellVariable.endMarker

/// A home folder with a shell of its own: a script run in place of the login shell, which exports what `exports` says, prints some
/// noise as a profile would, and then runs what it was asked to.
private struct Shell {
    let home: URL
    var path: String { home.appendingPathComponent("shell").path }

    init(exports: String, then: String = "exec /bin/sh -c \"$2\"") throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("login-var-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let record = "echo \"$@\" >>\"\(home.path)/asked\""
        let script = "#!/bin/sh\necho 'welcome to the shell'\n\(exports)\n\(record)\n\(then)\n"
        try script.write(toFile: home.appendingPathComponent("shell").path, atomically: true, encoding: .utf8)
        chmod(home.appendingPathComponent("shell").path, 0o755)
    }

    var asked: String? { try? String(contentsOf: home.appendingPathComponent("asked"), encoding: .utf8) }
    func cleanUp() { try? FileManager.default.removeItem(at: home) }

    func resolve(_ name: String, timeout: TimeInterval = 10) async -> String? {
        await LoginShellVariable.resolve(name, shell: path, home: home.path, path: "/usr/bin:/bin", timeout: timeout)
    }
}

@Suite(.processGate) struct LoginShellVariableTests {
    @Test func theValueTheShellExportsIsReadWhateverTheProfilePrints() async throws {
        let shell = try Shell(exports: "export GATEWAY_KEY='sk-a b$c\"d'")
        defer { shell.cleanUp() }
        #expect(await shell.resolve("GATEWAY_KEY") == "sk-a b$c\"d")
    }

    @Test func anUnsetOrEmptyVariableIsNothing() async throws {
        let shell = try Shell(exports: "export EMPTY_KEY=''")
        defer { shell.cleanUp() }
        #expect(await shell.resolve("EMPTY_KEY") == nil)
        #expect(await shell.resolve("NEVER_SET_ANYWHERE") == nil)
    }

    @Test(arguments: ["", "lower", "1X", "A;rm -rf /", "A$(id)", "A\nB", "A B", "A}"])
    func aNameThatIsNotAVariableNameNeverReachesAShell(name: String) async throws {
        let shell = try Shell(exports: "")
        defer { shell.cleanUp() }
        #expect(await shell.resolve(name) == nil)
        #expect(shell.asked == nil, "the shell was started for \(name)")
    }

    @Test(arguments: ["exit 3", "/bin/sh -c \"$2\"; exit 1"])
    func aShellThatFailsIsNotBelievedWhateverItPrinted(ending: String) async throws {
        let shell = try Shell(exports: "export GATEWAY_KEY=printed-before-failing", then: ending)
        defer { shell.cleanUp() }
        #expect(await shell.resolve("GATEWAY_KEY") == nil)
    }

    @Test func aShellThatHangsIsEndedAtTheDeadlineWithItsChild() async throws {
        // Ignores SIGTERM and leaves a child holding the pipes, after printing the value.
        let shell = try Shell(
            exports: "export GATEWAY_KEY=printed-then-hung",
            then: "/bin/sh -c \"$2\"; trap '' TERM; sleep 30 & echo $! >\"$HOME/child\"; wait")
        defer { shell.cleanUp() }
        let started = Date()
        // Long enough for a loaded machine to reach the child before the deadline ends the shell.
        #expect(await shell.resolve("GATEWAY_KEY", timeout: 8) == nil)
        #expect(Date().timeIntervalSince(started) < 25, "the deadline ended it, not the 30 s sleep")
        let text = try String(contentsOf: shell.home.appendingPathComponent("child"), encoding: .utf8)
        let child = try #require(pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(await FakeClaude.waitUntilGone(child), "and its child is gone")
    }

    @Test func theValueNeverPassesThroughAFile() async throws {
        // While the shell is still running, no temporary file holds what it has already printed.
        let secret = "on-disk-check-\(UUID().uuidString)"
        let shell = try Shell(
            exports: "export GATEWAY_KEY=\(secret)", then: "/bin/sh -c \"$2\"; touch \"$HOME/printed\"; sleep 2")
        defer { shell.cleanUp() }
        async let value = shell.resolve("GATEWAY_KEY")
        let printed = shell.home.appendingPathComponent("printed").path
        #expect(await pollUntil { FileManager.default.fileExists(atPath: printed) })
        let temp = FileManager.default.temporaryDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: temp.path)) ?? []
        for name in names where name.hasPrefix("wb-") {
            let url = temp.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url) else { continue }
            #expect(data.range(of: Data(secret.utf8)) == nil, "the key is in \(name)")
        }
        #expect(await value == secret)
    }

    @Test func onlyACleanValueBetweenTheMarkersIsTaken() {
        #expect(LoginShellVariable.parse("noise\(startMark)key-1\(endMark)more") == "key-1")
        #expect(LoginShellVariable.parse("\(startMark)\(endMark)") == nil)
        #expect(LoginShellVariable.parse("\(startMark)two\nlines\(endMark)") == nil)
        #expect(LoginShellVariable.parse("no markers") == nil)
        #expect(LoginShellVariable.parse("\(startMark)cut off") == nil)
        let long = String(repeating: "k", count: LoginShellVariable.maxLength + 1)
        #expect(LoginShellVariable.parse("\(startMark)\(long)\(endMark)") == nil)
    }

    @Test func theKeyOfTheProjectsGatewayIsGivenToAProcessThatHasNoneAndNeverReplaced() async throws {
        let shell = try Shell(exports: "export COMPANY_KEY=from-the-shell-0123")
        defer { shell.cleanUp() }
        let fx = try await RunnerFixture(
            extraConfig: "[providers.opencode]\nbase_url = \"https://gw.example/v1\"\napi_key_env = \"COMPANY_KEY\"\n")
        let base = ["SHELL": shell.path, "HOME": shell.home.path, "PATH": "/usr/bin:/bin"]
        let given = Box()
        await LoginShellVariable.fillGatewayKey(project: fx.project, environment: base) { given.set($0, $1) }
        #expect(given.values == ["COMPANY_KEY": "from-the-shell-0123"])

        let kept = Box()
        var has = base
        has["COMPANY_KEY"] = "already-here-4567"
        await LoginShellVariable.fillGatewayKey(project: fx.project, environment: has) { kept.set($0, $1) }
        #expect(kept.values.isEmpty, "a key the process has is not replaced")
    }

    @Test func aProjectWithNoGatewayStartsNoShell() async throws {
        let shell = try Shell(exports: "export LITELLM_API_KEY=unused-0123456789")
        defer { shell.cleanUp() }
        let fx = try await RunnerFixture()
        let given = Box()
        await LoginShellVariable.fillGatewayKey(
            project: fx.project, environment: ["SHELL": shell.path, "HOME": shell.home.path]
        ) { given.set($0, $1) }
        #expect(given.values.isEmpty && shell.asked == nil)
    }

    #if os(macOS)
        @Test func aRealInteractiveZshReadsItFromZshrc() async throws {
            let home = FileManager.default.temporaryDirectory.appendingPathComponent("login-zsh-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: home) }
            try "export ZSHRC_ONLY_KEY=from-zshrc-0123\n".write(
                to: home.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
            let value = await LoginShellVariable.resolve(
                "ZSHRC_ONLY_KEY", shell: "/bin/zsh", home: home.path, path: "/usr/bin:/bin")
            #expect(value == "from-zshrc-0123", "a variable set in .zshrc, which only an interactive shell reads")
        }
    #endif
}

/// What `set` was called with.
private final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var kept: [String: String] = [:]
    var values: [String: String] { lock.withLock { kept } }
    func set(_ name: String, _ value: String) { lock.withLock { kept[name] = value } }
}
