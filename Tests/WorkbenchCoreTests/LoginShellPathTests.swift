import Foundation
import Testing

@testable import WorkbenchCore

@Suite(.processGate) struct LoginShellPathTests {
    /// A stand-in shell: a script that ignores its arguments and prints `body`.
    private func shell(_ body: String) throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("login-shell-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("fake-shell")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    private func printing(_ path: String, around noise: String = "") -> String {
        "printf '%s' '\(noise)'; printf '%s%s%s' '\(LoginShellPath.startMarker)' '\(path)' '\(LoginShellPath.endMarker)'; "
            + "printf '%s' '\(noise)'"
    }

    @Test func theLoginShellsPathComesFirstAndNothingTheAppHadIsLost() async throws {
        let fake = try shell(printing("/opt/homebrew/bin:/usr/bin:/home/me/.local/bin"))
        let path = await LoginShellPath.resolve(shell: fake, current: "/usr/bin:/bin")
        #expect(path == "/opt/homebrew/bin:/usr/bin:/home/me/.local/bin:/bin")
    }

    @Test func whatAProfilePrintsAroundThePathIsIgnored() async throws {
        let fake = try shell(printing("/opt/homebrew/bin", around: "Welcome back!\\n/not/a/path: noise "))
        let path = await LoginShellPath.resolve(shell: fake, current: "/usr/bin")
        #expect(path == "/opt/homebrew/bin:/usr/bin")
    }

    @Test func aShellThatCannotBeAskedLeavesThePathAsItWas() async throws {
        let current = "/usr/bin:/bin"
        #expect(await LoginShellPath.resolve(shell: "/no/such/shell", current: current) == current)
        #expect(await LoginShellPath.resolve(shell: "relative-shell", current: current) == current)
        let silent = try shell("echo nothing useful")
        #expect(await LoginShellPath.resolve(shell: silent, current: current) == current, "no markers")
        let failing = try shell("exit 3")
        #expect(await LoginShellPath.resolve(shell: failing, current: current) == current)
    }

    @Test func aShellThatHangsIsGivenUpOnAtTheTimeout() async throws {
        let slow = try shell("sleep 30")
        let started = ContinuousClock.now
        let path = await LoginShellPath.resolve(shell: slow, current: "/usr/bin", timeout: 0.5)
        #expect(path == "/usr/bin" && ContinuousClock.now - started < .seconds(10))
    }

    @Test func onlyAbsoluteEntriesAreTakenFromWhatTheShellSays() {
        let out = "x\(LoginShellPath.startMarker)/a/bin::relative/bin:.:/b/bin\(LoginShellPath.endMarker)y"
        #expect(LoginShellPath.parse(out) == "/a/bin:/b/bin")
        #expect(LoginShellPath.parse("\(LoginShellPath.startMarker)rel:\(LoginShellPath.endMarker)") == nil)
        #expect(LoginShellPath.parse("no markers") == nil)
        #expect(LoginShellPath.parse("\(LoginShellPath.endMarker)/a\(LoginShellPath.startMarker)") == nil, "end before start")
    }

    @Test func mergingKeepsEachEntryOnceInOrder() {
        #expect(LoginShellPath.merge(login: "/a:/b:/a", current: "/b:/c:") == "/a:/b:/c")
    }
}
