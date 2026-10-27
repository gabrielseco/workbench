import Foundation
import Testing

@testable import WorkbenchCore

/// A throwaway HOME with a git identity, so `workbench new` can commit and finds its global config there.
private struct NewHome {
    let home: URL
    let work: URL

    init(globalConfig: String? = nil) throws {
        let base = Scratch.url("newcmd")
        home = base.appendingPathComponent("home").resolvingSymlinksInPath()
        work = base.appendingPathComponent("work").resolvingSymlinksInPath()
        for url in [home, work] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        try "[user]\n\tname = t\n\temail = t@example.com\n".write(
            to: home.appendingPathComponent(".gitconfig"), atomically: true, encoding: .utf8)
        if let globalConfig {
            let file = home.appendingPathComponent(".workbench/config.toml")
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try globalConfig.write(to: file, atomically: true, encoding: .utf8)
        }
    }

    func run(_ arguments: [String], in directory: URL? = nil) async throws -> (code: Int32?, text: String) {
        var spawn = SpawnRequest(
            executable: WorkbenchBinary.executable, arguments: arguments,
            environment: ["PATH": "/usr/bin:/bin", "HOME": home.path, "USER": NSUserName()],
            workingDirectory: directory ?? work, timeout: 60)
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
        return (code, (lines + [exit?.stderrTail ?? ""]).joined(separator: "\n"))
    }

    func exists(_ relative: String, under base: URL) -> Bool {
        FileManager.default.fileExists(atPath: base.appendingPathComponent(relative).path)
    }
}

@Suite(.processGate) struct NewCommandTests {
    @Test func usesProjectsDirFromTheGlobalConfig() async throws {
        let h = try NewHome(globalConfig: "projects_dir = \"~/code\"\n[agents.run]\nmodel = \"haiku\"\n")
        let result = try await h.run(["new", "mocks-kit"])
        #expect(result.code == 0, "\(result.text)")
        let root = h.home.appendingPathComponent("code/mocks-kit")
        #expect(h.exists(".git", under: root) && h.exists(".workbench/config.toml", under: root))
        #expect(result.text.contains("workbench goal new"))
        let config = try Config.load(from: root.appendingPathComponent(".workbench/config.toml"))
        #expect(config.agents.run.model == "haiku")
    }

    @Test func inBeatsProjectsDirAndAPathBeatsBoth() async throws {
        let h = try NewHome(globalConfig: "projects_dir = \"~/code\"\n")
        let elsewhere = h.work.appendingPathComponent("clients")
        #expect(try await h.run(["new", "a", "--in", elsewhere.path]).code == 0)
        #expect(h.exists("a/.git", under: elsewhere))
        #expect(!h.exists("code/a", under: h.home))

        let explicit = h.work.appendingPathComponent("anywhere/b")
        let both = try await h.run(["new", explicit.path, "--in", elsewhere.path])
        #expect(both.code == 0 && both.text.contains("--in is ignored"), "\(both.text)")
        #expect(h.exists(".git", under: explicit))
        #expect(!h.exists("b", under: elsewhere))

        // `~/…` is expanded by Workbench, and a relative path is relative to where it ran.
        #expect(try await h.run(["new", "~/tilde-proj"]).code == 0)
        #expect(h.exists("tilde-proj/.git", under: h.home))
        #expect(try await h.run(["new", "./rel-proj"]).code == 0)
        #expect(h.exists("rel-proj/.git", under: h.work))
    }

    @Test func theProjectConfigIsTheOnlyOneARunReadsSoItWinsOverLaterGlobalChanges() async throws {
        let h = try NewHome(globalConfig: "projects_dir = \"~/p\"\n[agents.run]\nmodel = \"haiku\"\n")
        #expect(try await h.run(["new", "kit"]).code == 0)
        let configURL = h.home.appendingPathComponent("p/kit/.workbench/config.toml")
        #expect(try Config.load(from: configURL).agents.run.model == "haiku")

        let edited = try String(contentsOf: configURL, encoding: .utf8)
            .replacingOccurrences(of: "model = \"haiku\"", with: "model = \"opus\"")
        try edited.write(to: configURL, atomically: true, encoding: .utf8)
        try "projects_dir = \"~/p\"\n[agents.run]\nmodel = \"sonnet\"\n".write(
            to: h.home.appendingPathComponent(".workbench/config.toml"), atomically: true, encoding: .utf8)
        #expect(try Config.load(from: configURL).agents.run.model == "opus")
    }

    @Test func noLocationIsRefusedAndNothingIsCreatedInTheCurrentDirectory() async throws {
        let h = try NewHome()
        let result = try await h.run(["new", "orphan"])
        #expect(result.code == 2)
        #expect(result.text.contains("projects_dir"))
        #expect(!h.exists("orphan", under: h.work))
    }

    @Test func badNameAndNonEmptyTargetAndNestingExitWithTheirKinds() async throws {
        let h = try NewHome()
        #expect(try await h.run(["new", "a b", "--in", h.work.path]).code == 2)
        #expect(try await h.run(["new", "--evil", "--in", h.work.path]).code == 2)

        let busy = h.work.appendingPathComponent("busy")
        try FileManager.default.createDirectory(at: busy, withIntermediateDirectories: true)
        try "x".write(to: busy.appendingPathComponent("f"), atomically: true, encoding: .utf8)
        let notEmpty = try await h.run(["new", "busy", "--in", h.work.path])
        #expect(notEmpty.code == 6 && notEmpty.text.contains("not empty"), "\(notEmpty.text)")

        #expect(try await h.run(["new", "outer", "--in", h.work.path]).code == 0)
        let outer = h.work.appendingPathComponent("outer")
        let inside = try await h.run(["new", "inner", "--in", outer.path])
        #expect(inside.code == 6 && inside.text.contains("--nested"), "\(inside.text)")
        #expect(!h.exists("inner", under: outer))
        #expect(try await h.run(["new", "inner", "--in", outer.path, "--nested"]).code == 0)
    }

    @Test func seedsAreCopiedAndABadGlobalKeyIsReported() async throws {
        let h = try NewHome(globalConfig: "projects_dir = \"~/p\"\n")
        let src = h.work.appendingPathComponent("crm/src/mocks")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try "export const a = 1\n".write(to: src.appendingPathComponent("a.ts"), atomically: true, encoding: .utf8)
        let result = try await h.run(["new", "kit", "--seed", "crm/src/mocks"])
        #expect(result.code == 0, "\(result.text)")
        #expect(h.exists("p/kit/vendor/mocks/a.ts", under: h.home))

        let missing = try await h.run(["new", "kit2", "--seed", "crm/nope"])
        #expect(missing.code == 7)
        #expect(!h.exists("p/kit2", under: h.home))

        try "check_command = \"make\"\n".write(
            to: h.home.appendingPathComponent(".workbench/config.toml"), atomically: true, encoding: .utf8)
        let bad = try await h.run(["new", "kit3", "--in", h.work.path])
        #expect(bad.code == 2 && bad.text.contains("'check_command' is not allowed in the global config"), "\(bad.text)")
    }

    @Test func aThreadRunsToAcceptInANewProjectWithNoRemoteAndShipSaysSo() async throws {
        let h = try NewHome(globalConfig: "projects_dir = \"~/p\"\nclaude_path = \"\(FakeClaude.executable.path)\"\n")
        #expect(try await h.run(["new", "fresh"]).code == 0)
        let root = h.home.appendingPathComponent("p/fresh")
        let configURL = root.appendingPathComponent(".workbench/config.toml")
        let text = try String(contentsOf: configURL, encoding: .utf8)
        try ("env_pass = [\"FAKE_CLAUDE\"]\n" + text).write(to: configURL, atomically: true, encoding: .utf8)

        let git = try isolatedGit()
        let project = Project(root: root)
        let service = ThreadService(project: project, git: git)
        let id = try await service.newThread(name: "first", base: "main")
        var goal = try String(contentsOf: project.goalURL(id), encoding: .utf8)
        for (placeholder, value) in [
            ("TODO(workbench): say what should change, in a few sentences.", "Add a file."),
            ("TODO(workbench): something that can be checked.", "w.txt exists."),
            ("TODO(workbench): how it will be shown (a test, a command, a screenshot).", "ls"),
            ("TODO(workbench): what must not change.", "Nothing else."),
        ] { goal = goal.replacingOccurrences(of: placeholder, with: value) }
        try goal.write(to: project.goalURL(id), atomically: true, encoding: .utf8)
        try await service.approve(id: id)

        var options = RunOptions(feedback: nil)
        options.timeoutOverride = 20
        options.parentEnvironment = [
            "PATH": "/usr/bin:/bin", "HOME": h.home.path, "USER": NSUserName(), "FAKE_CLAUDE": "",
        ]
        let report = try await ThreadRunner(project: project, threadID: id, git: git) { _ in }.run(options)
        #expect(report.result == .succeeded)

        let review = try await h.run(["review", id], in: root)
        #expect(review.code == 0, "\(review.text)")

        try "w\n".write(
            to: project.worktreesDirectory.appendingPathComponent(id).appendingPathComponent("w.txt"),
            atomically: true, encoding: .utf8)
        let accepted = try await h.run(["accept", id, "-m", "feat: add w", "--yes"], in: root)
        #expect(accepted.code == 0, "\(accepted.text)")

        let shipped = try await h.run(["ship", id, "--yes"], in: root)
        #expect(shipped.code == 6, "\(shipped.text)")
        #expect(shipped.text.contains("no remote named origin"), "\(shipped.text)")
    }
}
