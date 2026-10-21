import Foundation
import Testing

@testable import WorkbenchCore

/// A temporary folder holding executable scripts.
private struct Bin {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("wb-editor-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    @discardableResult
    func script(_ name: String, _ body: String) throws -> String {
        let file = url.appendingPathComponent(name)
        try "#!/bin/sh\n\(body)\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return file.path
    }
}

@Suite struct EditorTests {
    @Test func theFlagWinsThenTheProjectThenTheGlobalConfig() {
        #expect(EditorChoice.resolve(flag: "a", project: "b", global: "c") == EditorChoice(value: "a", source: .flag))
        #expect(EditorChoice.resolve(flag: nil, project: "b", global: "c") == EditorChoice(value: "b", source: .project))
        #expect(EditorChoice.resolve(flag: nil, project: nil, global: "c") == EditorChoice(value: "c", source: .global))
        #expect(EditorChoice.resolve(flag: nil, project: nil, global: nil) == nil)
    }

    @Test func aKnownNameRunsItsLauncherFromPath() throws {
        let bin = try Bin()
        let cursor = try bin.script("cursor", "exit 0")
        let command = try Editor.command(for: "cursor", path: "/w", searchPath: "/nowhere:\(bin.url.path)", isMacOS: true)
        #expect(command == EditorCommand(executable: cursor, arguments: ["/w"]))
    }

    @Test func aMissingLauncherOnMacOSFallsBackToOpenWithTheAppName() throws {
        let bin = try Bin()
        let open = try bin.script("open", "exit 0")
        for (name, app) in Editor.known {
            let command = try Editor.command(for: name, path: "/w", searchPath: "/nowhere", isMacOS: true, openExecutable: open)
            #expect(command == EditorCommand(executable: open, arguments: ["-a", app, "/w"]))
        }
        #expect(Editor.known.map(\.app) == ["Cursor", "Visual Studio Code", "Zed", "Sublime Text", "Windsurf"])
    }

    @Test func nothingToRunIsNotFoundNamingWhatWasTried() {
        #expect(throws: EditorError.notFound(editor: "zed", tried: ["'zed' on PATH"])) {
            try Editor.command(for: "zed", path: "/w", searchPath: "/nowhere", isMacOS: false)
        }
        #expect(throws: EditorError.notFound(editor: "zed", tried: ["'zed' on PATH", "/nowhere/open -a \"Zed\""])) {
            try Editor.command(for: "zed", path: "/w", searchPath: "/nowhere", isMacOS: true, openExecutable: "/nowhere/open")
        }
        #expect(throws: EditorError.notFound(editor: "/nowhere/ed -w", tried: ["/nowhere/ed"])) {
            try Editor.command(for: "/nowhere/ed -w", path: "/w", searchPath: "/usr/bin", isMacOS: true)
        }
        let message = EditorError.notFound(editor: "zed", tried: ["'zed' on PATH", "/usr/bin/open -a \"Zed\""]).description
        #expect(message.contains("zed") && message.contains("on PATH, then /usr/bin/open -a \"Zed\""))
    }

    @Test func aCustomCommandKeepsItsArgumentsAndGetsThePathLast() throws {
        let bin = try Bin()
        let ed = try bin.script("my-ed", "exit 0")
        let named = try Editor.command(for: "my-ed --new-window", path: "/w", searchPath: bin.url.path, isMacOS: true)
        #expect(named == EditorCommand(executable: ed, arguments: ["--new-window", "/w"]))
        let absolute = try Editor.command(for: "\(ed)  -n", path: "/w", searchPath: nil, isMacOS: false)
        #expect(absolute == EditorCommand(executable: ed, arguments: ["-n", "/w"]))
    }

    @Test func relativePathEntriesAreNotSearched() throws {
        let bin = try Bin()
        try bin.script("zed", "exit 0")
        let relative = bin.url.path.split(separator: "/").joined(separator: "/")  // the same folder, without the leading /
        #expect(throws: EditorError.self) {
            try Editor.command(for: "zed", path: "/w", searchPath: relative, isMacOS: false)
        }
    }

    @Test func valuesFollowTheCheckCommandsRulesAndAPathMustBeAbsolute() {
        for good in ["cursor", "code", "zed", "subl", "windsurf", "nvim-qt --nofork", "/opt/bin/ed -w"] {
            #expect(Editor.valueProblem(good) == nil, "\(good)")
        }
        for bad in ["", "  ", "-x", "code && rm x", "code | tee", "ed $(x)", "ed \"a b\"", "ed 'a'", "bin/ed", "./ed"] {
            #expect(Editor.valueProblem(bad) != nil, "\(bad)")
        }
    }

    @Test func theLauncherEnvironmentIsAFixedSmallSet() {
        let parent = [
            "PATH": "/bin", "HOME": "/h", "LANG": "C", "LC_ALL": "C", "ANTHROPIC_API_KEY": "k", "GH_TOKEN": "t",
            "TERM": "xterm", "EDITOR": "vim",
        ]
        #expect(Editor.environment(from: parent) == ["PATH": "/bin", "HOME": "/h", "LANG": "C", "LC_ALL": "C"])
    }
}

@Suite struct EditorLauncherTests {
    private let here = FileManager.default.temporaryDirectory

    @Test func aLauncherThatExitsZeroIsDone() async throws {
        let bin = try Bin()
        let marker = bin.url.appendingPathComponent("ran")
        let ed = try bin.script("ed", "touch '\(marker.path)'")
        try await EditorLauncher.launch(
            EditorCommand(executable: ed, arguments: ["/w"]), editor: "ed", in: here, environment: [:])
        #expect(FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func aNonZeroExitIsReportedWithTheLastOutputLine() async throws {
        let bin = try Bin()
        let ed = try bin.script("ed", "echo first\necho 'cannot open window' >&2\necho\nexit 4")
        await #expect(throws: EditorError.failed(editor: "ed", how: "exited 4", lastLine: "cannot open window")) {
            try await EditorLauncher.launch(
                EditorCommand(executable: ed, arguments: []), editor: "ed", in: here, environment: [:])
        }
    }

    @Test func aLauncherThatHangsIsStoppedAtTheTimeoutAndReported() async throws {
        let bin = try Bin()
        let pidFile = bin.url.appendingPathComponent("pid")
        let ed = try bin.script("ed", "echo $$ > '\(pidFile.path)'\nexec sleep 60")
        let started = Date()
        await #expect(throws: EditorError.timedOut(editor: "ed", seconds: 1)) {
            try await EditorLauncher.launch(
                EditorCommand(executable: ed, arguments: []), editor: "ed", in: here, environment: [:], timeout: 1,
                killGrace: 1)
        }
        #expect(Date().timeIntervalSince(started) < 5)
        let pid = try #require(Int32(try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .newlines)))
        #expect(kill(pid, 0) == -1, "the launcher is gone")
    }

    @Test func aLauncherThatIgnoresSigtermIsKilledAfterTheGrace() async throws {
        let bin = try Bin()
        let ed = try bin.script("ed", "trap '' TERM\nwhile :; do sleep 1; done")
        let started = Date()
        await #expect(throws: EditorError.timedOut(editor: "ed", seconds: 1)) {
            try await EditorLauncher.launch(
                EditorCommand(executable: ed, arguments: []), editor: "ed", in: here, environment: [:], timeout: 1,
                killGrace: 1)
        }
        #expect(Date().timeIntervalSince(started) < 6)
    }

    @Test func whatTheLauncherStartsAndLeavesRunningIsNotKilled() async throws {
        let bin = try Bin()
        let pidFile = bin.url.appendingPathComponent("app")
        // The app outlives its launcher, as `code` leaves the editor running.
        let ed = try bin.script("ed", "sleep 30 >/dev/null 2>&1 &\necho $! > '\(pidFile.path)'\nexit 0")
        try await EditorLauncher.launch(
            EditorCommand(executable: ed, arguments: []), editor: "ed", in: here, environment: [:])
        let pid = try #require(Int32(try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .newlines)))
        #expect(kill(pid, 0) == 0, "the app is still running")
        kill(pid, SIGKILL)
    }
}
