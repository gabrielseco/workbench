import Foundation
import Testing

@testable import WorkbenchCore

/// A `herdr-app` that is a shell script: it writes down every call, and its answers come from files in one folder, so a test can close
/// the window, show spaces, refuse a command, or hang. It answers the way the real one does: pretty-printed JSON on stdout, `{"error":
/// "<sentence>"}` and exit 1 for a refusal, exit 2 and "no Herdr window" on stderr when no window is open.
private final class FakeHerdr: @unchecked Sendable {
    let dir: URL
    var executable: URL { dir.appendingPathComponent("herdr-app") }
    private let lock = NSLock()
    private var launched = 0

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("fake-herdr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = """
            #!/bin/sh
            echo "$@" >> "$FAKE_HERDR_DIR/calls"
            refuse() { printf '{\\n  "error": "%s"\\n}\\n' "$1"; exit 1; }
            if [ -f "$FAKE_HERDR_DIR/down" ]; then echo "herdr-app: no Herdr window at /x/sock" >&2; exit 2; fi
            case "$1 $2" in
              "ls ")
                if [ -f "$FAKE_HERDR_DIR/lsfail" ]; then refuse "herdr is unwell"; fi
                if [ -f "$FAKE_HERDR_DIR/spaces" ]; then cat "$FAKE_HERDR_DIR/spaces"
                else printf '{\\n  "spaces": [],\\n  "recent": []\\n}\\n'; fi ;;
              "do space.new")
                if [ -f "$FAKE_HERDR_DIR/hang" ]; then
                  echo $$ > "$FAKE_HERDR_DIR/pid"; sleep 30 & echo $! > "$FAKE_HERDR_DIR/childpid"; wait
                fi
                if [ -f "$FAKE_HERDR_DIR/nocreate" ]; then refuse "cannot start a terminal: line one"; fi
                printf '{\\n  "space": "sp9",\\n  "tab": "tb9",\\n  "terminal": "t9"\\n}\\n' ;;
              "do space.select") printf '{\\n  "ok": true\\n}\\n' ;;
              *) refuse "unexpected: $*" ;;
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
        try place("herdr-app", in: bin)
        let found = find()
        #expect(found?.path == bin.appendingPathComponent("herdr-app").path)
        // A Dock-launched app has a bare PATH: the usual install place is looked in.
        try FileManager.default.removeItem(at: bin)
        try place("herdr-app", in: home.appendingPathComponent(".local/bin"))
        let bare = HerdrLocator.find(configured: nil, searchPath: "/nowhere", home: home.path, extraDirectories: places)
        #expect(bare != nil)
    }

    @Test func aConfiguredStandInIsNeverSkippedForARealOne() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("locator-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try place("herdr-app", in: root.appendingPathComponent("bin"))
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
    @Test func startsTheAppOnlyWhenItsWindowIsNotOpen() async throws {
        let up = try FakeHerdr()
        _ = try await up.opener().open(folder: folder, label: "t1")
        // Open already: it is only brought forward, once, after the space exists.
        #expect(up.launches == 1 && up.calls.last == "do space.new --name t1 --folder /work/project-wt/t1")

        let down = try FakeHerdr()
        try down.set("down")
        _ = try await down.opener().open(folder: folder, label: "t1")
        // Started once, asked until the window answered, and only then given a space.
        #expect(down.launches == 1)
        #expect(down.calls.first == "ls" && down.calls.last == "do space.new --name t1 --folder /work/project-wt/t1")
    }

    @Test func aRunningAppIsBroughtForwardByTheLauncherYouGaveIt() async throws {
        let fake = try FakeHerdr()
        var opener = fake.opener()
        opener.bringForward = {}  // a stand-in's: the real launcher must not run
        _ = try await opener.open(folder: folder, label: "t1")
        #expect(fake.launches == 0)
    }

    @Test func aProbeThatFailsForAnotherReasonIsThrownAndNothingElseIsStarted() async throws {
        let fake = try FakeHerdr()
        try fake.set("lsfail")
        do {
            _ = try await fake.opener().open(folder: folder, label: "t1")
            Issue.record("a herdr that was unwell was asked to open something")
        } catch let failure as HerdrFailure {
            #expect(failure.code == "refused" && failure.message == "herdr is unwell")
        }
        #expect(fake.calls == ["ls"] && fake.launches == 0)
    }

    @Test func waitsABoundedTimeForTheWindowAfterStartingTheApp() async throws {
        let never = try FakeHerdr()
        try never.set("down")
        var opener = never.opener(startupWait: 0.3)
        opener.launchApp = { [never] in _ = never }  // starts, but the window never comes up
        do {
            _ = try await opener.open(folder: folder, label: "t1")
            Issue.record("a window that never came up was opened into")
        } catch let failure as HerdrFailure {
            #expect(failure.windowDown)
            #expect(failure.message.hasPrefix("Herdr was started but its window did not come up"))
        }
        #expect(never.calls.allSatisfy { $0 == "ls" })
    }

    @Test func makesASpaceForTheFolderAndSelectsTheOneItHas() async throws {
        let fake = try FakeHerdr()
        let first = try await fake.opener().open(folder: folder, label: "t1")
        #expect(first == HerdrOpened(space: "sp9", alreadyOpen: false))
        #expect(fake.calls.contains("do space.new --name t1 --folder /work/project-wt/t1"))

        try fake.set(
            "spaces",
            text: #"{"spaces":[{"id":"sp1","folder":"/elsewhere"},{"id":"sp3","folder":"/work/project-wt/t1"}],"recent":[]}"#)
        let again = try await fake.opener().open(folder: folder, label: "t1")
        #expect(again == HerdrOpened(space: "sp3", alreadyOpen: true))
        #expect(fake.calls.contains("do space.select --id sp3"))
        #expect(fake.calls.filter { $0.hasPrefix("do space.new") }.count == 1)
    }

    @Test func anErrorShowsOneLineAndTheAppIsNotWorkedAround() async throws {
        let fake = try FakeHerdr()
        try fake.set("nocreate")
        do {
            _ = try await fake.opener().open(folder: folder, label: "t1")
            Issue.record("a refused space opened something")
        } catch let failure as HerdrFailure {
            #expect(failure.code == "refused" && !failure.message.contains("\n"))
            #expect(failure.message == "cannot start a terminal: line one")
        }
        #expect(fake.launches == 0)
    }

    @Test func aHangIsStoppedWithItsProcessGroupAndLeavesNothing() async throws {
        let fake = try FakeHerdr()
        try fake.set("hang")
        let started = Date()
        // Long enough that a busy machine has started the script and it has written its pids before the stop comes.
        do {
            _ = try await fake.opener(timeout: 3).open(folder: folder, label: "t1")
            Issue.record("a hung herdr-app was waited for")
        } catch let failure as HerdrFailure {
            #expect(failure.code == "timeout" && failure.message.contains("did not answer within 3 seconds"))
        }
        #expect(Date().timeIntervalSince(started) < 15)
        let pid = try #require(Int32((try? String(contentsOf: fake.dir.appendingPathComponent("pid"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""))
        let child = try #require(Int32((try? String(contentsOf: fake.dir.appendingPathComponent("childpid"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""))
        for _ in 0..<50 where kill(pid, 0) == 0 || kill(child, 0) == 0 { try await Task.sleep(for: .milliseconds(100)) }
        #expect(kill(pid, 0) != 0, "the hung herdr-app is still running")
        #expect(kill(child, 0) != 0, "what the hung herdr-app started is still running")
    }
}
