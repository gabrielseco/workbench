import Foundation
import Testing

@testable import WorkbenchCore

struct CLIRan {
    var code: Int32?
    var stdout: String
    var stderr: String
}

/// Runs the built binary with exactly this environment: `HOME` decides which global config it reads.
func workbenchCLI(_ arguments: [String], in directory: URL, environment: [String: String]) async throws -> CLIRan {
    var spawn = SpawnRequest(
        executable: WorkbenchBinary.executable, arguments: arguments, environment: environment,
        workingDirectory: directory, timeout: 60)
    spawn.snapshotInterval = 3600
    let run = try ProcessRunner.start(spawn)
    var lines: [String] = []
    var exit: ProcessExit?
    for await event in run.events {
        if case .line(let line) = event { lines.append(line) }
        if case .exited(let e) = event { exit = e }
    }
    var code: Int32?
    if case .exited(let c)? = exit?.termination { code = c }
    return CLIRan(code: code, stdout: lines.joined(separator: "\n"), stderr: exit?.stderrTail ?? "")
}

/// A project with a thread, a private HOME and a bin folder of fake launchers that record their arguments.
struct OpenFixture {
    let fx: RunnerFixture
    let id: String
    let home: URL
    let bin: URL
    let record: URL

    init(worktree: Bool = true) async throws {
        fx = try await RunnerFixture()
        id = try await fx.approvedThread()
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("wb-open-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        home = scratch.appendingPathComponent("home")
        bin = scratch.appendingPathComponent("bin")
        record = scratch.appendingPathComponent("record.txt")
        for dir in [home, bin] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        // `zed` stands for a known editor's launcher, `rec` for a custom command: both write one argument per line.
        for name in ["zed", "rec"] {
            try launcher(name, body: "for a in \"$@\"; do echo \"$a\"; done > '\(record.path)'")
        }
        if worktree { _ = try await WorktreeManager(repoRoot: fx.repo, git: fx.git).create(threadID: id, base: "main") }
    }

    var worktree: URL { fx.project.worktreesDirectory.appendingPathComponent(id).resolvingSymlinksInPath() }

    func launcher(_ name: String, body: String) throws {
        let url = bin.appendingPathComponent(name)
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    func globalConfig(_ text: String) throws {
        let dir = home.appendingPathComponent(".workbench")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try text.write(to: dir.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
    }

    func projectEditor(_ value: String) throws {
        let text = try String(contentsOf: fx.project.configURL, encoding: .utf8)
        try ("editor = \"\(value)\"\n" + text).write(to: fx.project.configURL, atomically: true, encoding: .utf8)
    }

    func open(_ arguments: [String], extra: [String: String] = [:]) async throws -> CLIRan {
        let env = ["PATH": "\(bin.path):/usr/bin:/bin", "HOME": home.path, "USER": NSUserName()]
        return try await workbenchCLI(
            ["open"] + arguments, in: fx.repo, environment: env.merging(extra) { $1 })
    }

    /// What the fake launcher was given, nil when nothing was launched.
    func recorded() -> [String]? {
        guard let text = try? String(contentsOf: record, encoding: .utf8) else { return nil }
        return text.split(separator: "\n").map(String.init)
    }
}

@Suite struct OpenCommandTests {
    @Test func opensTheActiveThreadsWorktreeInAKnownEditorFoundOnPath() async throws {
        let o = try await OpenFixture()
        let ran = try await o.open(["--editor", "zed"])
        #expect(ran.code == 0, "\(ran.stderr)")
        #expect(ran.stdout == "opened \(o.worktree.path) in zed")
        #expect(o.recorded() == [o.worktree.path])
    }

    @Test func opensANamedThreadWithACustomCommandThatGetsThePathLast() async throws {
        let o = try await OpenFixture()
        let ran = try await o.open([o.id, "--editor", "rec --new-window -a"])
        #expect(ran.code == 0, "\(ran.stderr)")
        #expect(o.recorded() == ["--new-window", "-a", o.worktree.path])
        #expect(ran.stdout == "opened \(o.worktree.path) in rec --new-window -a")
    }

    @Test func aThreadWithNoWorktreeIsRefusedAndNothingIsLaunched() async throws {
        let o = try await OpenFixture(worktree: false)
        let never = try await o.open(["--editor", "zed"])
        #expect(never.code == 6 && never.stderr.contains("workbench: refused: "), "\(never.stderr)")
        #expect(never.stderr.contains("has no worktree"))

        _ = try await WorktreeManager(repoRoot: o.fx.repo, git: o.fx.git).create(threadID: o.id, base: "main")
        try await WorktreeManager(repoRoot: o.fx.repo, git: o.fx.git).remove(threadID: o.id, force: true, deleteBranch: false)
        let gone = try await o.open([o.id, "--editor", "zed"])
        #expect(gone.code == 6 && gone.stderr.contains("has no worktree"), "\(gone.stderr)")
        #expect(o.recorded() == nil)
    }

    @Test func anUnknownThreadIsNotFoundAndNothingIsLaunched() async throws {
        let o = try await OpenFixture()
        let ran = try await o.open(["g-2026-01-01-nope", "--editor", "zed"])
        #expect(ran.code == 7 && ran.stderr.contains("no thread 'g-2026-01-01-nope'"), "\(ran.stderr)")
        #expect(o.recorded() == nil)
    }

    @Test func aWorktreeThatResolvesOutsideTheWorktreesFolderIsRefused() async throws {
        let o = try await OpenFixture(worktree: false)
        let elsewhere = o.home.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: o.fx.project.worktreesDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: o.fx.project.worktreesDirectory.appendingPathComponent(o.id), withDestinationURL: elsewhere)
        let ran = try await o.open(["--editor", "zed"])
        #expect(ran.code == 6 && ran.stderr.contains("outside .workbench/worktrees/"), "\(ran.stderr)")
        let printed = try await o.open(["--print"])
        #expect(printed.code == 6 && printed.stdout.isEmpty)
        #expect(o.recorded() == nil)
    }

    @Test func theEditorComesFromTheFlagThenTheProjectThenTheGlobalConfig() async throws {
        let o = try await OpenFixture()
        try o.globalConfig("editor = \"rec --global\"\n")
        let global = try await o.open([])
        #expect(global.code == 0 && o.recorded() == ["--global", o.worktree.path], "\(global.stderr)")

        try o.projectEditor("zed")
        let project = try await o.open([])
        #expect(project.code == 0 && project.stdout.hasSuffix(" in zed") && o.recorded() == [o.worktree.path])

        let flag = try await o.open(["--editor", "rec --flag"])
        #expect(flag.code == 0 && o.recorded() == ["--flag", o.worktree.path])
    }

    @Test func noEditorSetIsRefusedWithWhatToDoAndEditorIsNotUsed() async throws {
        let o = try await OpenFixture()
        let zed = o.bin.appendingPathComponent("zed").path
        let ran = try await o.open([], extra: ["EDITOR": zed, "VISUAL": zed])
        #expect(ran.code == 6, "\(ran.stderr)")
        for part in ["--editor", "`editor`", "--print"] { #expect(ran.stderr.contains(part), "\(ran.stderr)") }
        #expect(o.recorded() == nil)
    }

    @Test func printGivesOnlyThePathAndLaunchesNothing() async throws {
        let o = try await OpenFixture()
        let bare = try await o.open(["--print"])
        #expect(bare.code == 0 && bare.stdout == o.worktree.path && bare.stderr.isEmpty, "\(bare.stderr)")
        try o.projectEditor("zed")
        let configured = try await o.open([o.id, "--print"])
        #expect(configured.code == 0 && configured.stdout == o.worktree.path)
        let both = try await o.open(["--print", "--editor", "zed"])
        #expect(both.code == 2 && both.stderr.contains("--editor and --print"), "\(both.stderr)")
        #expect(o.recorded() == nil)
    }

    @Test func aLauncherThatFailsIsReportedWithItsLastLine() async throws {
        let o = try await OpenFixture()
        try o.launcher("broken", body: "echo starting\necho 'no such window' >&2\nexit 3")
        let ran = try await o.open(["--editor", "broken"])
        #expect(ran.code == 1, "\(ran.stderr)")
        #expect(ran.stderr.contains("exited 3") && ran.stderr.contains("no such window"), "\(ran.stderr)")
        #expect(!ran.stdout.contains("opened"))
    }

    @Test func aCommandThatCannotBeFoundIsRefusedNamingWhatWasTried() async throws {
        let o = try await OpenFixture()
        let ran = try await o.open(["--editor", "no-such-editor-xyz --wait"])
        #expect(ran.code == 6 && ran.stderr.contains("'no-such-editor-xyz' on PATH"), "\(ran.stderr)")
    }

    @Test func badValuesAreUsageOrConfigErrorsNamingTheKey() async throws {
        let o = try await OpenFixture()
        let flag = try await o.open(["--editor", "zed; rm -rf /"])
        #expect(flag.code == 2 && flag.stderr.contains("--editor must be a single plain command"), "\(flag.stderr)")
        try o.globalConfig("editor = \"code && evil\"\n")
        let global = try await o.open([])
        #expect(global.code == 2 && global.stderr.contains("invalid-config") && global.stderr.contains("'editor'"))
        try o.projectEditor("bin/relative")
        let project = try await o.open([])
        #expect(project.code == 2 && project.stderr.contains("'editor'"), "\(project.stderr)")
        #expect(o.recorded() == nil)
    }

    @Test func openWritesNoEventAndChangesNothingInTheThreadOrWorktree() async throws {
        let o = try await OpenFixture()
        try o.launcher("chatty", body: "echo 'lots of output'\necho 'and errors' >&2")
        let log = try Data(contentsOf: o.fx.project.eventsURL(o.id))
        let thread = try FileManager.default.contentsOfDirectory(atPath: o.fx.project.threadDirectory(o.id).path).sorted()
        let status = try await o.fx.git.run(["status", "--porcelain", "--ignored"], in: o.worktree).stdout
        #expect(try await o.open(["--editor", "chatty"]).code == 0)
        #expect(try await o.open(["--print"]).code == 0)
        #expect(try Data(contentsOf: o.fx.project.eventsURL(o.id)) == log, "the event log is byte for byte the same")
        #expect(try FileManager.default.contentsOfDirectory(atPath: o.fx.project.threadDirectory(o.id).path).sorted() == thread)
        #expect(try await o.fx.git.run(["status", "--porcelain", "--ignored"], in: o.worktree).stdout == status)
    }
}
