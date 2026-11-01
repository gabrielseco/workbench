import Foundation
import Testing

@testable import WorkbenchCore

/// A `launchctl` that records what it was asked and keeps a "loaded" flag, in a directory of its own.
private struct FakeLaunchctl {
    let dir: URL
    let runner: GitRunner

    init() throws {
        dir = try Scratch.directory("launchctl")
        let script = dir.appendingPathComponent("launchctl")
        try #"""
            #!/bin/sh
            d="$FAKE_DIR"
            echo "$@" >> "$d/calls"
            case "$1" in
            bootout) if [ -f "$d/loaded" ]; then rm "$d/loaded"; exit 0; fi; echo "no such service" >&2; exit 3 ;;
            bootstrap)
              if [ -f "$d/fail_bootstrap" ]; then echo "Bootstrap failed: 5: Input/output error" >&2; exit 5; fi
              touch "$d/loaded"; exit 0 ;;
            print)
              if [ -f "$d/loaded" ]; then
                code=$(cat "$d/exit" 2>/dev/null || echo 0)
                printf '\tstate = not running\n\truns = 3\n\tlast exit code = %s\n' "$code"
                printf '\trun interval = 900 seconds\n'
                exit 0
              fi
              echo "Could not find service" >&2; exit 113 ;;
            esac
            exit 2
            """#.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        runner = GitRunner(executable: script, environment: ["PATH": "/usr/bin:/bin", "FAKE_DIR": dir.path], timeout: 10)
    }

    var calls: [String] {
        let text = (try? String(contentsOf: dir.appendingPathComponent("calls"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map(String.init)
    }
    var loaded: Bool { FileManager.default.fileExists(atPath: dir.appendingPathComponent("loaded").path) }
    func put(_ name: String, _ text: String = "") throws {
        try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
}

/// A project with a task, a temporary HOME, the stand-in launchctl and probes that say what the test wants.
private struct Env {
    let task: TaskFixture
    let home: URL
    let launchctl: FakeLaunchctl
    let workbench = URL(fileURLWithPath: "/opt/wb/workbench")

    init(front: String = "at: 04:00\ndays: weekdays\nfix: pr") throws {
        task = try TaskFixture(front: front)
        home = try Scratch.directory("home")
        launchctl = try FakeLaunchctl()
    }

    func service(
        launchd: Bool = true, workbench: URL? = nil, sched: String? = nil, power: String? = nil, vault: String? = nil
    ) -> TimerService {
        TimerService(
            project: task.project, home: home, workbench: workbench ?? self.workbench,
            launchctl: launchd ? launchctl.runner : nil, uid: 501,
            probes: TimerProbes(sched: { sched }, power: { power }, fileVault: { vault }))
    }

    var paths: TimerPaths { TimerPaths(project: task.project, home: home) }
}

private let weekdaysAtFour = "Repeating power events:\n  wakepoweron at 3:55AM weekdays only\nScheduled power events:\n"

@Suite(.processGate) struct TaskTimerInstallTests {
    @Test func installWritesTheTwoFilesLoadsTheAgentAndSaysTheSudoLine() async throws {
        let env = try Env()
        let lines = try await env.service().install()
        let paths = env.paths
        #expect(FileManager.default.isExecutableFile(atPath: paths.launcher.path))
        let launcher = try String(contentsOf: paths.launcher, encoding: .utf8)
        #expect(launcher.contains("task tick") && launcher.contains("'/opt/wb/workbench'"))
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: paths.plist), format: nil)
        #expect((plist as? [String: Any])?["Label"] as? String == paths.label)
        // The only program run is launchctl: unload any old copy, then load this one.
        #expect(env.launchctl.calls == ["bootout gui/501/\(paths.label)", "bootstrap gui/501 \(paths.plist.path)"])
        #expect(env.launchctl.loaded)
        #expect(lines.first == "installed \(paths.label)")
        #expect(lines.contains("  sudo pmset repeat wakeorpoweron MTWRF 03:55:00"))
        #expect(lines.contains { $0.contains("it needs your password; Workbench does not run sudo") })
        #expect(lines.contains { $0.contains("plugged in and logged in") })
        #expect(lines.contains("check it any time with: workbench task timer status"))
    }

    @Test func installingAgainReplacesWhatItWrote() async throws {
        let env = try Env()
        _ = try await env.service().install()
        #expect(!(try String(contentsOf: env.paths.launcher, encoding: .utf8)).contains("git pull"))
        _ = try await env.service().install(interval: 300, pullMain: true)
        let launcher = try String(contentsOf: env.paths.launcher, encoding: .utf8)
        let plist = try String(contentsOf: env.paths.plist, encoding: .utf8)
        #expect(launcher.contains("git pull --ff-only") && plist.contains("<integer>300</integer>"))
        #expect(env.launchctl.calls.filter { $0.hasPrefix("bootstrap") }.count == 2 && env.launchctl.loaded)
        #expect(env.launchctl.calls.filter { $0.hasPrefix("bootout") }.count == 2)
    }

    @Test func aProjectWithoutATimeOfDayGetsNoWakeLineAndASentenceWhy() async throws {
        let env = try Env(front: "every: 1h\nfix: report")
        let lines = try await env.service().install()
        #expect(lines.contains { $0.hasPrefix("no wake schedule: tasks that run every so often") })
        #expect(!lines.contains { $0.contains("pmset repeat") })
    }

    @Test func aBuildInTheDebugFolderIsNotedBecauseARebuildReplacesIt() async throws {
        let env = try Env()
        let lines = try await env.service(workbench: URL(fileURLWithPath: "/code/wb/.build/debug/workbench")).install()
        #expect(lines.contains { $0.hasPrefix("note: it runs /code/wb/.build/debug/workbench; a rebuild replaces that file") })
        let plain = try await env.service().install()
        #expect(!plain.contains { $0.hasPrefix("note: it runs") })
    }

    @Test func aSystemWithNoLaunchdWritesNothingAndGivesTheCronLine() async throws {
        let env = try Env()
        await #expect(throws: TimerError.self) { try await env.service(launchd: false).install() }
        do {
            _ = try await env.service(launchd: false).install()
        } catch let error as TimerError {
            guard case .noLaunchd(let cron) = error else { Issue.record("wrong error \(error)"); return }
            #expect(cron.hasPrefix("*/15 * * * * cd '") && cron.hasSuffix("task tick"))
        }
        #expect(!FileManager.default.fileExists(atPath: env.home.appendingPathComponent(".workbench").path))
        #expect(env.launchctl.calls.isEmpty)
    }

    @Test func aLoadThatFailsIsReportedWithTheReason() async throws {
        let env = try Env()
        try env.launchctl.put("fail_bootstrap")
        await #expect(throws: TimerError.launchctlFailed("bootstrap", "Bootstrap failed: 5: Input/output error")) {
            try await env.service().install()
        }
    }

    @Test func removeUnloadsDeletesTheFilesLeavesTheLogAndSaysWhatToCancel() async throws {
        let env = try Env()
        _ = try await env.service().install()
        try FileManager.default.createDirectory(at: env.paths.log.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "--- tick\n".write(to: env.paths.log, atomically: true, encoding: .utf8)
        let lines = await env.service().remove()
        #expect(!env.launchctl.loaded)
        #expect(!FileManager.default.fileExists(atPath: env.paths.plist.path))
        #expect(!FileManager.default.fileExists(atPath: env.paths.launcherDirectory.path))
        #expect(FileManager.default.fileExists(atPath: env.paths.log.path))
        #expect(lines.contains("unloaded \(env.paths.label)"))
        #expect(lines.contains("if you set a wake schedule for it: sudo pmset repeat cancel"))
        #expect(await env.service().remove().first == "no timer was installed for this project")
    }

    @Test func noProgramButLaunchctlIsEverRun() async throws {
        // The service holds one runner, launchctl's; the wake line is printed, never run.
        let env = try Env()
        _ = try await env.service().install()
        _ = await env.service().remove()
        #expect(env.launchctl.calls.allSatisfy { $0.hasPrefix("bootout ") || $0.hasPrefix("bootstrap ") })
    }
}

@Suite(.processGate) struct TaskTimerStatusTests {
    private func lines(_ status: [TimerStatusLine]) -> [String] { status.map { "\($0.level.rawValue): \($0.text)" } }

    @Test func notInstalledSaysSo() async throws {
        let env = try Env()
        let status = lines(await env.service(sched: nil).status())
        #expect(status.contains("fail: agent: not installed: workbench task timer install"))
    }

    @Test func aHealthyTimerIsAllOk() async throws {
        let env = try Env()
        try await env.task.library.approve(env.task.name)
        _ = try await env.service().install()
        let ready = env.service(sched: weekdaysAtFour, power: "Now drawing from 'AC Power'", vault: "FileVault is Off.")
        let status = await ready.status()
        let text = lines(status)
        #expect(text.contains("ok: agent: loaded, every 15 min, ran 3 time(s), last exit code 0"))
        #expect(text.contains("ok: task bump: approved, weekdays 04:00"))
        #expect(text.contains("ok: wake: 03:55 weekdays only"))
        #expect(text.contains("ok: power: plugged in") && text.contains("ok: FileVault is off: the timer survives a restart"))
        #expect(status.allSatisfy { $0.level != .fail })
    }

    @Test func installedButNotLoadedIsAFailure() async throws {
        let env = try Env()
        _ = try await env.service().install()
        try FileManager.default.removeItem(at: env.launchctl.dir.appendingPathComponent("loaded"))
        let text = lines(await env.service().status())
        #expect(text.contains { $0.hasPrefix("fail: agent: installed but not loaded") })
    }

    @Test func aTickThatExitedBadlyIsFlagged() async throws {
        let env = try Env()
        _ = try await env.service().install()
        try env.launchctl.put("exit", "78")
        let text = lines(await env.service().status())
        #expect(text.contains { $0.hasPrefix("warn: the last tick exited 78") })
    }

    @Test func theWakeMustMatchWhatTheTasksNeed() async throws {
        let env = try Env()
        _ = try await env.service().install()
        let fix = "run: sudo pmset repeat wakeorpoweron MTWRF 03:55:00"
        let none = lines(await env.service(sched: "Repeating power events:\n").status())
        #expect(none.contains("warn: wake: no repeating wake is set; \(fix)"))
        let late = lines(await env.service(sched: "Repeating power events:\n  wakepoweron at 4:30AM weekdays only\n").status())
        #expect(late.contains("warn: wake: set for 04:30, the tasks need 03:55; \(fix)"))
        let days = lines(await env.service(sched: "Repeating power events:\n  wakepoweron at 3:55AM every day\n").status())
        #expect(days.contains { $0.hasPrefix("warn: wake: set for every day, the tasks need weekdays only") })
    }

    @Test func aProjectNeedingNoWakeIsNotToldToSetOne() async throws {
        let env = try Env(front: "every: 1h\nfix: report")
        _ = try await env.service().install()
        let text = lines(await env.service(sched: "").status())
        #expect(text.contains { $0.hasPrefix("ok: wake: not needed") })
    }

    @Test func batteryAndFileVaultAreWarnings() async throws {
        let env = try Env()
        _ = try await env.service().install()
        let text = lines(await env.service(power: "Now drawing from 'Battery Power'", vault: "FileVault is On.").status())
        #expect(text.contains("warn: power: on battery; plug in so a run is not cut short"))
        #expect(text.contains("warn: FileVault is on: after a restart nothing runs until you log in"))
    }

    @Test func staleAndBrokenTasksAreNamed() async throws {
        let env = try Env(front: "at: 04:00\ndays: weekdays\nfix: pr\npending: pending.sh")
        try env.task.script("echo '[]'")
        try await env.task.library.approve(env.task.name)
        _ = try await env.service().install()
        try env.task.write(task: "---\nat: 04:00\ndays: weekdays\nfix: pr\npending: pending.sh\n---\nChanged.\n")
        #expect(lines(await env.service().status()).contains("warn: task bump: STALE: workbench task approve bump"))
        try FileManager.default.removeItem(at: env.task.project.root.appendingPathComponent("pending.sh"))
        #expect(lines(await env.service().status()).contains { $0.hasPrefix("fail: task bump: cannot be loaded") })
    }

    @Test func aTaskWithNoScheduleIsFlaggedBecauseATickNeverRunsIt() async throws {
        let env = try Env(front: "fix: report")
        try await env.task.library.approve(env.task.name)
        _ = try await env.service().install()
        let text = lines(await env.service().status())
        #expect(text.contains { $0.hasPrefix("warn: task bump: approved but has no schedule") })
    }
}
