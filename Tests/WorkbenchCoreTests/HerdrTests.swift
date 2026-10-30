import Foundation
import Testing

@testable import WorkbenchCore

/// A `herdr` that is a shell script: it writes down every call, and its answers come from files in one folder, so a test can take the
/// server down, refuse a worktree, show panes, or hang.
private final class FakeHerdr: @unchecked Sendable {
    let dir: URL
    var executable: URL { dir.appendingPathComponent("herdr") }
    private let lock = NSLock()
    private var launched = 0

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("fake-herdr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = """
            #!/bin/sh
            echo "$@" >> "$FAKE_HERDR_DIR/calls"
            err() { printf '{"id":"x","error":{"code":"%s","message":"%s"}}\\n' "$1" "$2" >&2; exit 1; }
            if [ -f "$FAKE_HERDR_DIR/down" ]; then err server_not_running "no herdr server is running"; fi
            case "$1 $2" in
              "workspace list")
                if [ -f "$FAKE_HERDR_DIR/listfail" ]; then err internal_error "herdr is unwell"; fi
                echo '{"id":"x","result":{"type":"workspace_list","workspaces":[]}}' ;;
              "worktree open")
                if [ -f "$FAKE_HERDR_DIR/hang" ]; then
                  echo $$ > "$FAKE_HERDR_DIR/pid"; sleep 30 & echo $! > "$FAKE_HERDR_DIR/childpid"; wait
                fi
                if [ -f "$FAKE_HERDR_DIR/refuse" ]; then err worktree_not_found "worktree path not found"; fi
                if [ -f "$FAKE_HERDR_DIR/broken" ]; then err internal_error "herdr is unwell"; fi
                if [ -f "$FAKE_HERDR_DIR/open" ]; then
                  echo '{"id":"x","result":{"already_open":true,"workspace":{"workspace_id":"w1"},"type":"worktree_opened"}}'
                else
                  echo '{"id":"x","result":{"workspace":{"workspace_id":"w1"},"type":"worktree_opened"}}'
                fi ;;
              "pane list")
                if [ -f "$FAKE_HERDR_DIR/panes" ]; then cat "$FAKE_HERDR_DIR/panes"
                else echo '{"id":"x","result":{"panes":[]}}'; fi ;;
              "workspace create")
                if [ -f "$FAKE_HERDR_DIR/nocreate" ]; then err cannot_create "line one\\nline two"; fi
                echo '{"id":"x","result":{"workspace":{"workspace_id":"w9"},"type":"workspace_created"}}' ;;
              "workspace focus") echo '{"id":"x","result":{"type":"ok"}}' ;;
              *) err unknown "unexpected: $*" ;;
            esac
            """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    func set(_ flag: String, _ on: Bool = true, text: String = "") throws {
        let url = dir.appendingPathComponent(flag)
        if on { try text.write(to: url, atomically: true, encoding: .utf8) } else { try? FileManager.default.removeItem(at: url) }
    }

    var calls: [String] {
        ((try? String(contentsOf: dir.appendingPathComponent("calls"), encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    var launches: Int { lock.withLock { launched } }

    func opener(timeout: TimeInterval = 10, startupWait: TimeInterval = 5) -> HerdrOpener {
        let client = HerdrClient(
            executable: executable, environment: ["FAKE_HERDR_DIR": dir.path, "PATH": "/usr/bin:/bin"], timeout: timeout)
        var opener = HerdrOpener(client: client) { [self] in
            lock.withLock { launched += 1 }
            try set("down", false)
        }
        opener.startupWait = startupWait
        opener.pollInterval = 0.05
        return opener
    }
}

private let project = URL(fileURLWithPath: "/work/project")
private let folder = URL(fileURLWithPath: "/work/project-wt/t1")

@Suite struct HerdrLocatorTests {
    private func place(_ name: String, in dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try "#!/bin/sh\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    @Test func foundOnlyWhereItIs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("locator-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let (bin, home) = (root.appendingPathComponent("bin"), root.appendingPathComponent("home"))
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        // Only this folder's own places are searched: a herdr installed on the machine running the test must not count.
        let places = [home.appendingPathComponent(".local/bin").path]
        func find() -> URL? {
            HerdrLocator.find(configured: nil, searchPath: bin.path, home: home.path, extraDirectories: places)
        }
        #expect(find() == nil)
        try place("herdr", in: bin)
        let found = find()
        #expect(found?.path == bin.appendingPathComponent("herdr").path)
        // A Dock-launched app has a bare PATH: the usual install place is looked in.
        try FileManager.default.removeItem(at: bin)
        try place("herdr", in: home.appendingPathComponent(".local/bin"))
        let bare = HerdrLocator.find(configured: nil, searchPath: "/nowhere", home: home.path, extraDirectories: places)
        #expect(bare != nil)
    }

    @Test func aConfiguredStandInIsNeverSkippedForARealOne() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("locator-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try place("herdr", in: root.appendingPathComponent("bin"))
        try place("stand-in", in: root.appendingPathComponent("stub"))
        let stand = root.appendingPathComponent("stub/stand-in").path
        let search = root.appendingPathComponent("bin").path
        #expect(HerdrLocator.find(configured: stand, searchPath: search, home: root.path)?.path == stand)
        let missing = root.appendingPathComponent("stub/gone").path
        #expect(HerdrLocator.find(configured: missing, searchPath: search, home: root.path) == nil)
    }

    @Test func theConfigKeyTakesOneCommandOrAbsolutePath() {
        for good in ["herdr", "/opt/homebrew/bin/herdr", "/tmp/stand-in.sh"] { #expect(HerdrLocator.valueProblem(good) == nil) }
        for bad in ["", "herdr --x", "bin/herdr", "herdr;rm", "\"herdr\"", "$HOME/herdr", "a\nb"] {
            #expect(HerdrLocator.valueProblem(bad) != nil, "\(bad.debugDescription)")
        }
        #expect(throws: ConfigError.self) { try Config.parse("herdr = \"herdr --x\"\n[tools]\navailable = [\"Read\"]\n") }
        #expect((try? Config.parse("herdr = \"/opt/homebrew/bin/herdr\"\n[tools]\navailable = [\"Read\"]\n"))?.herdr != nil)
        #expect((try? GlobalConfig.parse("herdr = \"herdr\"\n"))?.herdr == "herdr")
    }
}

@Suite struct HerdrOpenTests {
    @Test func startsTheAppOnlyWhenTheServerIsDown() async throws {
        let up = try FakeHerdr()
        _ = try await up.opener().open(project: project, folder: folder, label: "t1")
        #expect(up.launches == 0)

        let down = try FakeHerdr()
        try down.set("down")
        _ = try await down.opener().open(project: project, folder: folder, label: "t1")
        #expect(down.launches == 1)
        // It asked until the server answered, and only then opened.
        let calls = down.calls
        #expect(calls.first == "workspace list" && calls.last?.hasPrefix("worktree open") == true)
    }

    @Test func aProbeThatFailsForAnotherReasonIsThrownAndNothingElseIsStarted() async throws {
        let fake = try FakeHerdr()
        try fake.set("listfail")
        do {
            _ = try await fake.opener().open(project: project, folder: folder, label: "t1")
            Issue.record("a herdr that was unwell was asked to open something")
        } catch let failure as HerdrFailure {
            #expect(failure.code == "internal_error" && failure.message == "herdr is unwell")
        }
        #expect(fake.calls == ["workspace list"] && fake.launches == 0)
    }

    @Test func waitsABoundedTimeForTheServerAfterStartingTheApp() async throws {
        let never = try FakeHerdr()
        try never.set("down")
        var opener = never.opener(startupWait: 0.3)
        opener.launchApp = { [never] in _ = never }  // starts, but the server never comes up
        await #expect(throws: HerdrFailure.self) { _ = try await opener.open(project: project, folder: folder, label: "t1") }
        #expect(never.calls.allSatisfy { $0 == "workspace list" })
    }

    @Test func opensTheWorktreeAndFallsBackToTheFolder() async throws {
        let fake = try FakeHerdr()
        let first = try await fake.opener().open(project: project, folder: folder, label: "t1")
        #expect(first == .worktree(workspace: "w1", alreadyOpen: false))
        #expect(fake.calls.contains("worktree open --cwd /work/project --path /work/project-wt/t1 --focus"))

        try fake.set("refuse")
        let second = try await fake.opener().open(project: project, folder: folder, label: "t1")
        #expect(second == .folder(workspace: "w9", alreadyOpen: false))
        #expect(fake.calls.contains("workspace create --cwd /work/project-wt/t1 --label t1 --focus"))
    }

    @Test func onlyANotAWorktreeAnswerSendsItToThePlainFolder() async throws {
        let fake = try FakeHerdr()
        try fake.set("broken")
        do {
            _ = try await fake.opener().open(project: project, folder: folder, label: "t1")
            Issue.record("an error of Herdr's own was worked around")
        } catch let failure as HerdrFailure {
            #expect(failure.code == "internal_error" && failure.message == "herdr is unwell")
        }
        // Nothing was started on top of it: no pane list, no workspace made.
        #expect(fake.calls.count == 2 && fake.calls.last?.hasPrefix("worktree open") == true)
    }

    @Test func aSecondClickFocusesInsteadOfCreating() async throws {
        let fake = try FakeHerdr()
        // Worktree: Herdr itself says it was already open.
        try fake.set("open")
        let again = try await fake.opener().open(project: project, folder: folder, label: "t1")
        #expect(again == .worktree(workspace: "w1", alreadyOpen: true))
        // Plain folder: a pane of another workspace is already in it.
        try fake.set("refuse")
        try fake.set(
            "panes",
            text: #"{"id":"x","result":{"panes":[{"cwd":"/elsewhere","workspace_id":"w1"},"#
                + #"{"cwd":"/work/project-wt/t1","workspace_id":"w3"}]}}"#)
        let opened = try await fake.opener().open(project: project, folder: folder, label: "t1")
        #expect(opened == .folder(workspace: "w3", alreadyOpen: true))
        #expect(fake.calls.contains("workspace focus w3") && !fake.calls.contains { $0.hasPrefix("workspace create") })
    }

    @Test func neverTrustsARepository() async throws {
        let fake = try FakeHerdr()
        _ = try await fake.opener().open(project: project, folder: folder, label: "t1")
        try fake.set("refuse")
        _ = try await fake.opener().open(project: project, folder: folder, label: "t1")
        #expect(!fake.calls.isEmpty && fake.calls.allSatisfy { !$0.contains("trust") })
    }

    @Test func anErrorShowsOneLineAndNothingElseIsStarted() async throws {
        let fake = try FakeHerdr()
        try fake.set("refuse")
        try fake.set("nocreate")
        do {
            _ = try await fake.opener().open(project: project, folder: folder, label: "t1")
            Issue.record("two refusals opened something")
        } catch let failure as HerdrFailure {
            #expect(failure.code == "cannot_create" && !failure.message.contains("\n"))
        }
        #expect(fake.launches == 0)
    }

    @Test func aHangIsStoppedWithItsProcessGroupAndLeavesNothing() async throws {
        let fake = try FakeHerdr()
        try fake.set("hang")
        let started = Date()
        // Long enough that a busy machine has started the script and it has written its pids before the stop comes.
        do {
            _ = try await fake.opener(timeout: 3).open(project: project, folder: folder, label: "t1")
            Issue.record("a hung herdr was waited for")
        } catch let failure as HerdrFailure {
            #expect(failure.code == "timeout" && failure.message.contains("did not answer within 3 seconds"))
        }
        #expect(Date().timeIntervalSince(started) < 15)
        let pid = try #require(Int32((try? String(contentsOf: fake.dir.appendingPathComponent("pid"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""))
        let child = try #require(Int32((try? String(contentsOf: fake.dir.appendingPathComponent("childpid"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""))
        for _ in 0..<50 where kill(pid, 0) == 0 || kill(child, 0) == 0 { try await Task.sleep(for: .milliseconds(100)) }
        #expect(kill(pid, 0) != 0, "the hung herdr is still running")
        #expect(kill(child, 0) != 0, "what the hung herdr started is still running")
    }
}
