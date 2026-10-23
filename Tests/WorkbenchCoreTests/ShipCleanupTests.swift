import Foundation
import Testing

@testable import WorkbenchCore

private struct Cmd {
    var code: Int32?
    var text: String
}

private func ship(_ arguments: [String], fx: RunnerFixture, gh: FakeGH) async throws -> Cmd {
    var spawn = SpawnRequest(
        executable: WorkbenchBinary.executable, arguments: ["ship"] + arguments,
        environment: [
            "PATH": "\(gh.dir.path):/usr/bin:/bin", "HOME": NSHomeDirectory(), "USER": NSUserName(),
            "GH_FAKE_DIR": gh.dir.path,
        ],
        workingDirectory: fx.repo, timeout: 120)
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
    return Cmd(code: code, text: (lines + [exit?.stderrTail ?? ""]).joined(separator: "\n"))
}

/// Shipped through the services (which do not clean up), so each test starts from "shipped, worktree there".
private struct Shipped {
    var id: String
    var worktree: URL
    var bare: URL
}

private func shipped(_ fx: RunnerFixture, _ gh: FakeGH) async throws -> Shipped {
    let (id, worktree) = try await acceptedThread(fx)
    let bare = try await addOrigin(fx)
    _ = try await fx.service.shipPush(id: id, gh: gh.runner)
    _ = try await fx.service.shipOpenPR(id: id, gh: gh.runner)
    return Shipped(id: id, worktree: worktree, bare: bare)
}

@Suite(.processGate) struct ShipCleanupTests {
    @Test func aShippedCleanThreadLosesItsWorktreeAndKeepsItsBranch() async throws {
        let fx = try await RunnerFixture()
        let gh = try FakeGH(in: fx)
        let thread = try await shipped(fx, gh)
        let (id, worktree) = (thread.id, thread.worktree)

        let result = await fx.service.cleanShipped(id: id, gh: gh.runner)
        #expect(result == .removed(path: worktree.path))
        #expect(!FileManager.default.fileExists(atPath: worktree.path))
        #expect(try await shipOut(["worktree", "list", "--porcelain"], fx.repo, fx).contains(worktree.path) == false)
        #expect(try await shipOut(["rev-parse", "--verify", "workbench/\(id)"], fx.repo, fx).count == 40)
        let last = try #require(try fx.events(id).last)
        #expect(last.kind == .worktreeRemoved && last.data["reason"]?.stringValue == "shipped")

        // Once gone it does nothing and writes nothing more.
        let count = try fx.events(id).count
        #expect(await fx.service.cleanShipped(id: id, gh: gh.runner) == .alreadyGone)
        #expect(try fx.events(id).count == count)
    }

    @Test func nothingIsRemovedWhenSomethingCouldBeLost() async throws {
        let fx = try await RunnerFixture()
        let gh = try FakeGH(in: fx)
        let thread = try await shipped(fx, gh)
        let (id, worktree, bare) = (thread.id, thread.worktree, thread.bare)

        func kept(_ label: String) async throws {
            let result = await fx.service.cleanShipped(id: id, gh: gh.runner)
            guard case .kept(let why) = result else {
                Issue.record("\(label): got \(result)")
                return
            }
            #expect(FileManager.default.fileExists(atPath: worktree.path), Comment(rawValue: "\(label): \(why)"))
            #expect(!(try fx.events(id).contains { $0.kind == .worktreeRemoved }), Comment(rawValue: label))
        }

        // An untracked file.
        try "x".write(to: worktree.appendingPathComponent("loose.txt"), atomically: true, encoding: .utf8)
        try await kept("untracked")
        try FileManager.default.removeItem(at: worktree.appendingPathComponent("loose.txt"))

        // Newer work than what was shipped.
        try "more\n".write(to: worktree.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        _ = try await fx.git.run(["add", "-A"], in: worktree)
        _ = try await fx.git.run(["commit", "-q", "-m", "after the PR"], in: worktree)
        try await kept("newer commit")
        _ = try await fx.git.run(["reset", "-q", "--hard", "HEAD~1"], in: worktree)

        // Origin moved to something else.
        let clone = fx.repo.deletingLastPathComponent().appendingPathComponent("c-\(UUID().uuidString)")
        _ = try await fx.git.run(["clone", "-q", "-b", "workbench/\(id)", bare.path, clone.path], in: fx.repo)
        try "z".write(to: clone.appendingPathComponent("z.txt"), atomically: true, encoding: .utf8)
        _ = try await fx.git.run(["add", "-A"], in: clone)
        _ = try await fx.git.run(["commit", "-q", "-m", "z"], in: clone)
        _ = try await fx.git.run(["push", "-q", "origin", "HEAD:refs/heads/workbench/\(id)"], in: clone)
        try await kept("origin differs")
        _ = try await fx.git.run(["push", "-q", "-f", bare.path, "HEAD:refs/heads/workbench/\(id)"], in: worktree)

        // A live runner.
        let me = getpid()
        let started = try #require(ProcessTree.member(for: me))
        let info: [String: Any] = [
            "pid": me, "started_seconds": started.startSeconds, "started_micros": started.startMicros,
        ]
        try JSONSerialization.data(withJSONObject: info).write(to: fx.project.runnerURL(id))
        try await kept("live runner")
        try FileManager.default.removeItem(at: fx.project.runnerURL(id))

        // And with the cause gone it is removed.
        #expect(await fx.service.cleanShipped(id: id, gh: gh.runner) == .removed(path: worktree.path))
    }

    @Test func aRemovalWithoutARecordIsRecordedByTheNextRun() async throws {
        let fx = try await RunnerFixture()
        let gh = try FakeGH(in: fx)
        let thread = try await shipped(fx, gh)
        // As if the process died after removing and before writing the event.
        _ = try await fx.git.run(["worktree", "remove", thread.worktree.path], in: fx.repo)

        #expect(await fx.service.cleanShipped(id: thread.id, gh: gh.runner) == .alreadyGone)
        let recorded = try fx.events(thread.id).filter { $0.kind == .worktreeRemoved }
        #expect(recorded.count == 1)
        #expect(recorded.first?.data["head_sha"]?.stringValue?.count == 40)
        #expect(await fx.service.cleanShipped(id: thread.id, gh: gh.runner) == .alreadyGone)
        #expect(try fx.events(thread.id).filter { $0.kind == .worktreeRemoved }.count == 1)

        let line = LogFormatter.describe(try #require(recorded.first))
        #expect(line.contains("worktree removed (shipped)") && line.contains("branch is kept"), "\(line)")
    }

    @Test func aLeftoverRegistrationIsPrunedBeforeTheRemovalIsDeclaredDone() async throws {
        let fx = try await RunnerFixture()
        let gh = try FakeGH(in: fx)
        let thread = try await shipped(fx, gh)
        // The directory was deleted by hand: git still lists it.
        try FileManager.default.removeItem(at: thread.worktree)
        #expect(try await shipOut(["worktree", "list", "--porcelain"], fx.repo, fx).contains(thread.worktree.path))

        #expect(await fx.service.cleanShipped(id: thread.id, gh: gh.runner) == .alreadyGone)
        #expect(!(try await shipOut(["worktree", "list", "--porcelain"], fx.repo, fx).contains(thread.worktree.path)))
        #expect(try fx.events(thread.id).filter { $0.kind == .worktreeRemoved }.count == 1)
    }

    @Test func twoRunsRecordingTheSameRemovalWriteOneEvent() async throws {
        let fx = try await RunnerFixture()
        let gh = try FakeGH(in: fx)
        let thread = try await shipped(fx, gh)
        _ = try await fx.git.run(["worktree", "remove", thread.worktree.path], in: fx.repo)

        async let first = fx.service.cleanShipped(id: thread.id, gh: gh.runner)
        async let second = fx.service.cleanShipped(id: thread.id, gh: gh.runner)
        _ = await (first, second)
        #expect(try fx.events(thread.id).filter { $0.kind == .worktreeRemoved }.count == 1)
        #expect(try fx.contents(thread.id).isHealthy)
    }

    @Test func aWrongBranchAndAStagedChangeAreKept() async throws {
        let fx = try await RunnerFixture()
        let gh = try FakeGH(in: fx)
        let thread = try await shipped(fx, gh)
        try "s\n".write(to: thread.worktree.appendingPathComponent("s.txt"), atomically: true, encoding: .utf8)
        _ = try await fx.git.run(["add", "s.txt"], in: thread.worktree)
        guard case .kept = await fx.service.cleanShipped(id: thread.id, gh: gh.runner) else {
            Issue.record("a staged file must keep the worktree")
            return
        }
        _ = try await fx.git.run(["reset", "-q", "--hard"], in: thread.worktree)
        _ = try await fx.git.run(["clean", "-qfd"], in: thread.worktree)
        _ = try await fx.git.run(["checkout", "-q", "--detach"], in: thread.worktree)
        guard case .kept(let why) = await fx.service.cleanShipped(id: thread.id, gh: gh.runner) else {
            Issue.record("a detached HEAD must keep the worktree")
            return
        }
        #expect(why.contains("not on"))
        #expect(FileManager.default.fileExists(atPath: thread.worktree.path))
    }

    @Test func childrenADeadRunnerLeftAreSweptBeforeRemoval() async throws {
        let fx = try await RunnerFixture()
        let gh = try FakeGH(in: fx)
        let thread = try await shipped(fx, gh)
        let null = open("/dev/null", O_WRONLY)
        defer { close(null) }
        let sh = try Spawner.spawn(
            executable: "/bin/sh", arguments: ["-c", "exec sleep 300 &"], environment: ["PATH": "/usr/bin:/bin"],
            workingDirectory: thread.worktree.path, stdout: null, stderr: null)
        var status: Int32 = 0
        waitpid(sh, &status, 0)
        var orphan: ProcessMember?
        let deadline = Date().addingTimeInterval(Patience.limit)
        while orphan == nil, Date() < deadline {
            orphan = OrphanSweeper.orphans(inside: thread.worktree).first
            if orphan == nil { try await Task.sleep(nanoseconds: 50_000_000) }
        }
        let member = try #require(orphan, "a leftover child to sweep")

        #expect(await fx.service.cleanShipped(id: thread.id, gh: gh.runner) == .removed(path: thread.worktree.path))
        defer { kill(member.pid, SIGKILL) }
        #expect(await FakeClaude.waitUntilGone(member.pid), "the leftover child is gone")
        #expect(try fx.kinds(thread.id).contains("orphans.swept"))
    }

    @Test func aThreadThatIsNotShippedIsLeftAlone() async throws {
        let fx = try await RunnerFixture()
        let gh = try FakeGH(in: fx)
        let (id, worktree) = try await acceptedThread(fx)
        _ = try await addOrigin(fx)
        #expect(await fx.service.cleanShipped(id: id, gh: gh.runner) == .notShipped)
        #expect(FileManager.default.fileExists(atPath: worktree.path))
    }

    @Test func shipRemovesTheWorktreeAndAKeepFlagLeavesIt() async throws {
        let fx = try await RunnerFixture()
        let gh = try FakeGH(in: fx)
        let (id, worktree) = try await acceptedThread(fx)
        _ = try await addOrigin(fx)

        let first = try await ship(["--yes"], fx: fx, gh: gh)
        #expect(first.code == 0, Comment(rawValue: first.text))
        #expect(first.text.contains("removed the worktree"))
        #expect(!FileManager.default.fileExists(atPath: worktree.path))
        #expect(first.text.components(separatedBy: "\n").last { !$0.isEmpty } == "https://github.com/o/r/pull/12")
        #expect(try fx.events(id).filter { $0.kind == .worktreeRemoved }.count == 1)

        for command in ["status", "review", "log"] {
            var spawn = SpawnRequest(
                executable: WorkbenchBinary.executable, arguments: [command, id],
                environment: ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "USER": NSUserName()],
                workingDirectory: fx.repo, timeout: 60)
            spawn.snapshotInterval = 3600
            var text = ""
            var code: Int32?
            for await event in try ProcessRunner.start(spawn).events {
                if case .line(let l) = event { text += l + "\n" }
                if case .exited(let e) = event, case .exited(let c) = e.termination { code = c }
            }
            #expect(code == 0, "\(command): \(text)")
            if command == "status" { #expect(text.contains("removed after shipping")) }
            if command == "review" { #expect(text.contains("removed after shipping")) }
            if command == "log" { #expect(text.contains("worktree removed (shipped)"), Comment(rawValue: text)) }
        }

        // Shipped again: exit 4, URL last, no second removal event.
        let again = try await ship(["--yes", id], fx: fx, gh: gh)
        #expect(again.code == 11, Comment(rawValue: again.text))
        #expect(try fx.events(id).filter { $0.kind == .worktreeRemoved }.count == 1)
    }

    @Test func keepWorktreeLeavesItAndALaterShipOfTheShippedThreadRemovesIt() async throws {
        let fx = try await RunnerFixture()
        let gh = try FakeGH(in: fx)
        let (id, worktree) = try await acceptedThread(fx)
        _ = try await addOrigin(fx)

        let kept = try await ship(["--yes", "--keep-worktree"], fx: fx, gh: gh)
        #expect(kept.code == 0, Comment(rawValue: kept.text))
        #expect(FileManager.default.fileExists(atPath: worktree.path))
        #expect(!(try fx.events(id).contains { $0.kind == .worktreeRemoved }))

        let later = try await ship(["--yes", id], fx: fx, gh: gh)
        #expect(later.code == 11, Comment(rawValue: later.text))
        #expect(later.text.contains("removed the worktree"))
        #expect(!FileManager.default.fileExists(atPath: worktree.path))
    }
}

@Suite(.processGate) struct IgnoredFilesTests {
    private func shipped(_ fx: RunnerFixture, _ gh: FakeGH) async throws -> (id: String, worktree: URL) {
        let (id, worktree) = try await acceptedThread(fx)
        _ = try await addOrigin(fx)
        _ = try await fx.service.shipPush(id: id, gh: gh.runner)
        _ = try await fx.service.shipOpenPR(id: id, gh: gh.runner)
        return (id, worktree)
    }

    private func ignore(_ patterns: String, in worktree: URL, _ fx: RunnerFixture) async throws {
        let exclude = try await shipOut(["rev-parse", "--git-path", "info/exclude"], worktree, fx)
        let url = exclude.hasPrefix("/") ? URL(fileURLWithPath: exclude) : worktree.appendingPathComponent(exclude)
        // `.workbench/` stays ignored, as in a real clone (Workbench keeps it in info/exclude): the run's goal copy is in it.
        try (".workbench/\n" + patterns).write(to: url, atomically: true, encoding: .utf8)
    }

    @Test func theWorkbenchFolderIsListedAsIgnoredContentRemovedWithTheWorktree() {
        // Git reports the folder as one entry, so a log a run left beside the goal copy is named by it.
        let inventory = ThreadService.inventory(of: "!! .workbench/\n!! node_modules/\n")
        #expect(inventory.names == [".workbench/", "node_modules/"])
    }

    @Test func ignoredFilesDoNotKeepAWorktreeAndTheEventNamesThem() async throws {
        let fx = try await RunnerFixture()
        let gh = try FakeGH(in: fx)
        let (id, worktree) = try await shipped(fx, gh)
        try await ignore("node_modules/\n*.cache\n", in: worktree, fx)
        let fm = FileManager.default
        try fm.createDirectory(at: worktree.appendingPathComponent("node_modules/pkg"), withIntermediateDirectories: true)
        try "x".write(to: worktree.appendingPathComponent("node_modules/pkg/i.js"), atomically: true, encoding: .utf8)
        try "x".write(to: worktree.appendingPathComponent("a.cache"), atomically: true, encoding: .utf8)

        #expect(await fx.service.cleanShipped(id: id, gh: gh.runner, dryRun: true) == .removed(path: worktree.path))
        #expect(await fx.service.cleanShipped(id: id, gh: gh.runner) == .removed(path: worktree.path))
        #expect(!fm.fileExists(atPath: worktree.path))
        let event = try #require(try fx.events(id).last { $0.kind == .worktreeRemoved })
        guard case .array(let listed)? = event.data["ignored"] else {
            Issue.record("the event names what was ignored")
            return
        }
        // `.workbench/` holds the run's goal copy, and anything else a run left in it: all of it goes with the worktree.
        #expect(Set(listed.compactMap(\.stringValue)) == [".workbench/", "a.cache", "node_modules/"])
        #expect(event.data["ignored_more"] == nil)
    }

    @Test func anUntrackedFileBesideIgnoredOnesStillKeepsTheWorktree() async throws {
        let fx = try await RunnerFixture()
        let gh = try FakeGH(in: fx)
        let (id, worktree) = try await shipped(fx, gh)
        try await ignore("node_modules/\n", in: worktree, fx)
        try FileManager.default.createDirectory(
            at: worktree.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
        try "x".write(to: worktree.appendingPathComponent("node_modules/i.js"), atomically: true, encoding: .utf8)
        try "mine".write(to: worktree.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        guard case .kept(let why) = await fx.service.cleanShipped(id: id, gh: gh.runner) else {
            Issue.record("an untracked file must keep the worktree")
            return
        }
        #expect(why.contains("notes.txt"))
    }

    @Test func aStatusThatMayHaveBeenCutShortBlocksRemoval() {
        let line = "?? some/deep/path/file.js\n"
        let long = String(repeating: line, count: GitRunner.outputLimit / line.utf8.count + 1)
        #expect(ThreadService.statusProblem(long)?.contains("too long") == true)
        #expect(ThreadService.statusProblem(line)?.contains("some/deep/path/file.js") == true)
        #expect(ThreadService.statusProblem("") == nil)
    }

    @Test func theIgnoredInventoryIsBoundedAndSaysWhenItIsIncomplete() {
        let many = (0..<25).map { "!! dir\($0)/" }.joined(separator: "\n") + "\n M a.txt\n"
        let inventory = ThreadService.inventory(of: many)
        #expect(inventory.names.count == 20 && inventory.more == 5 && inventory.complete)
        #expect(inventory.names.first == "dir0/")

        let line = "!! some/deep/path/file.js\n"
        let cut = String(repeating: line, count: GitRunner.outputLimit / line.utf8.count + 1)
        #expect(!ThreadService.inventory(of: cut).complete)
        #expect(ThreadService.IgnoredInventory(complete: false).names.isEmpty)
    }
}
