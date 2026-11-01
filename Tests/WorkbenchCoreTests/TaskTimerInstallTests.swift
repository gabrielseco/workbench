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
            bootout)
              if [ -f "$d/fail_bootout" ]; then echo "Boot-out failed: 5: Input/output error" >&2; exit 5; fi
              if [ -f "$d/loaded" ]; then rm "$d/loaded"; exit 0; fi; echo "no such service" >&2; exit 3 ;;
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
    /// A real file: install copies it. Its text is what the copy must have.
    let workbench: URL

    init(front: String = "at: 04:00\ndays: weekdays\nfix: pr") throws {
        task = try TaskFixture(front: front)
        home = try Scratch.directory("home")
        launchctl = try FakeLaunchctl()
        let bin = try Scratch.directory("build")
        workbench = bin.appendingPathComponent("workbench")
        try "#!/bin/sh\necho v1\n".write(to: workbench, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: workbench.path)
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
        #expect(launcher.contains("task tick") && launcher.contains("'\(paths.binary.path)'"))
        #expect(!launcher.contains(env.workbench.path))
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

    private func text(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

    @Test func installCopiesTheBinary() async throws {
        let env = try Env()
        _ = try await env.service().install()
        #expect(text(env.paths.binary) == "#!/bin/sh\necho v1\n")
        #expect(FileManager.default.isExecutableFile(atPath: env.paths.binary.path))
        // A rebuild of the source changes nothing the launcher runs.
        try "#!/bin/sh\necho v2\n".write(to: env.workbench, atomically: true, encoding: .utf8)
        #expect(text(env.paths.binary) == "#!/bin/sh\necho v1\n")
    }

    @Test func installAgainRefreshesTheCopy() async throws {
        let env = try Env()
        _ = try await env.service().install()
        try "#!/bin/sh\necho v2\n".write(to: env.workbench, atomically: true, encoding: .utf8)
        _ = try await env.service().install()
        #expect(text(env.paths.binary) == "#!/bin/sh\necho v2\n")
    }

    @Test func installFromTheCopyKeepsIt() async throws {
        let env = try Env()
        _ = try await env.service().install()
        _ = try await env.service(workbench: env.paths.binary).install()
        #expect(text(env.paths.binary) == "#!/bin/sh\necho v1\n")
        #expect(FileManager.default.isExecutableFile(atPath: env.paths.binary.path))
    }

    @Test func aFailedCopyKeepsTheOldBinary() async throws {
        let env = try Env()
        _ = try await env.service().install()
        let launcher = text(env.paths.launcher)
        let gone = env.workbench.deletingLastPathComponent().appendingPathComponent("not-built")
        await #expect(throws: TimerError.self) { _ = try await env.service(workbench: gone).install() }
        #expect(text(env.paths.binary) == "#!/bin/sh\necho v1\n")
        #expect(text(env.paths.launcher) == launcher)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: env.paths.launcherDirectory.path)
        #expect(leftovers.sorted() == ["tick.sh", "workbench"])
        // A source that is a folder is not a binary either.
        let folder = env.workbench.deletingLastPathComponent()
        await #expect(throws: TimerError.self) { _ = try await env.service(workbench: folder).install() }
        #expect(text(env.paths.binary) == "#!/bin/sh\necho v1\n")
    }

    @Test func aCopyCutShortByAKilledInstallerIsSweptByTheNextInstall() async throws {
        let env = try Env()
        _ = try await env.service().install()
        let stale = env.paths.launcherDirectory.appendingPathComponent(".workbench-copy-DEAD")
        try "half".write(to: stale, atomically: true, encoding: .utf8)
        _ = try await env.service().install()
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(text(env.paths.binary) == "#!/bin/sh\necho v1\n")
    }

    @Test func noCopyNoInstall() async throws {
        let env = try Env()
        let gone = env.workbench.deletingLastPathComponent().appendingPathComponent("not-built")
        await #expect(throws: TimerError.self) { _ = try await env.service(workbench: gone).install() }
        #expect(!FileManager.default.fileExists(atPath: env.paths.launcher.path))
        #expect(!FileManager.default.fileExists(atPath: env.paths.plist.path))
        #expect(env.launchctl.calls.isEmpty)
    }

    @Test func installSaysWhereTheCopyIsAndHasNoRebuildNote() async throws {
        let env = try Env()
        let lines = try await env.service().install()
        #expect(lines.contains { $0.hasPrefix("  binary:   \(env.paths.binary.path) (a copy of \(env.workbench.path)") })
        #expect(!lines.contains { $0.contains("a rebuild replaces that file") })
    }

    @Test func removeDeletesTheCopy() async throws {
        let env = try Env()
        _ = try await env.service().install()
        _ = await env.service().remove()
        #expect(!FileManager.default.fileExists(atPath: env.paths.binary.path))
    }

    @Test func aSystemWithNoLaunchdWritesNothingAndGivesTheCronLine() async throws {
        let env = try Env()
        await #expect(throws: TimerError.self) { try await env.service(launchd: false).install() }
        do {
            _ = try await env.service(launchd: false).install()
        } catch let error as TimerError {
            guard case .noLaunchd(let cron, let note) = error else { Issue.record("wrong error \(error)"); return }
            #expect(cron.hasPrefix("*/15 * * * * cd '") && cron.hasSuffix("task tick") && note == nil)
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
        let removed = await env.service().remove()
        let lines = removed.lines
        #expect(removed.ok && !env.launchctl.loaded)
        #expect(!FileManager.default.fileExists(atPath: env.paths.plist.path))
        #expect(!FileManager.default.fileExists(atPath: env.paths.launcherDirectory.path))
        #expect(FileManager.default.fileExists(atPath: env.paths.log.path))
        #expect(lines.contains("unloaded \(env.paths.label)"))
        #expect(lines.contains("if you set a wake schedule for it: sudo pmset repeat cancel"))
        #expect(await env.service().remove().lines.first == "no timer was installed for this project")
    }

    @Test func aRemoveThatCannotUnloadKeepsTheFilesAndFails() async throws {
        let env = try Env()
        _ = try await env.service().install()
        try env.launchctl.put("fail_bootout")
        let result = await env.service().remove()
        #expect(!result.ok)
        #expect(result.lines.first?.hasPrefix("could not unload \(env.paths.label)") == true)
        #expect(result.lines.contains { $0.hasPrefix("nothing was deleted; try: launchctl bootout") })
        // What is on disk and what runs still agree.
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: env.paths.plist.path) && fm.fileExists(atPath: env.paths.launcher.path))
    }

    @Test func aLaunchctlThatCannotBeRunLeavesTheFilesAndFails() async throws {
        let env = try Env()
        _ = try await env.service().install()
        // launchctl does not start (or does not answer): the agent may still be loaded, so nothing is deleted.
        let missing = GitRunner(executable: URL(fileURLWithPath: "/nonexistent/launchctl"), environment: [:], timeout: 5)
        let service = TimerService(
            project: env.task.project, home: env.home, workbench: env.workbench, launchctl: missing, uid: 501,
            probes: TimerProbes(sched: { nil }, power: { nil }, fileVault: { nil }))
        let result = await service.remove()
        #expect(!result.ok && result.lines.first?.hasPrefix("could not unload \(env.paths.label)") == true)
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: env.paths.plist.path) && fm.fileExists(atPath: env.paths.launcher.path))
    }

    @Test func anAgentThatIsNotLoadedIsNotAFailureToRemove() async throws {
        let env = try Env()
        _ = try await env.service().install()
        try FileManager.default.removeItem(at: env.launchctl.dir.appendingPathComponent("loaded"))
        let result = await env.service().remove()
        #expect(result.ok && !FileManager.default.fileExists(atPath: env.paths.plist.path))
    }

    @Test(.enabled(if: geteuid() != 0, "root can delete a file in a folder with no write permission"))
    func aFileThatCannotBeDeletedIsReportedNotClaimed() async throws {
        let env = try Env()
        _ = try await env.service().install()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: env.paths.launcherDirectory.path)
        let folder = env.paths.launcherDirectory.path
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder) }
        let result = await env.service().remove()
        #expect(!result.ok)
        #expect(result.lines.contains { $0.hasPrefix("could not delete \(env.paths.launcher.path)") })
        #expect(!result.lines.contains("removed \(env.paths.launcher.path)"))
        #expect(FileManager.default.fileExists(atPath: env.paths.launcher.path))
    }

    @Test func removeOnASystemWithNoLaunchdSaysNothingWasInstalled() async throws {
        let env = try Env()
        let result = await env.service(launchd: false).remove()
        #expect(result.ok)
        #expect(result.lines.first?.hasPrefix("this system has no launchd: Workbench installed nothing here") == true)
        #expect(env.launchctl.calls.isEmpty)
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
        #expect(text.contains("ok: power: plugged in"))
        // The timer is a user agent: with FileVault off it still starts at login, so that is what is said.
        let off = "ok: FileVault is off: after a restart the timer starts when you log in (automatic login does that for you)"
        #expect(text.contains(off))
        #expect(status.allSatisfy { $0.level != .fail })
    }

    @Test func theCopyIsReportedAndAnOlderOneWarnsAndAMissingOneFails() async throws {
        let env = try Env()
        _ = try await env.service().install()
        let text = lines(await env.service().status())
        #expect(text.contains { $0.hasPrefix("ok: binary: \(env.paths.binary.path)") })
        // Rebuilt after the copy was made: the timer would run an old version.
        let later = Date().addingTimeInterval(120)
        try FileManager.default.setAttributes([.modificationDate: later], ofItemAtPath: env.workbench.path)
        let stale = lines(await env.service().status())
        let warned = stale.contains {
            $0.hasPrefix("warn: binary: the copy the launcher runs is from") && $0.hasSuffix("workbench task timer install")
        }
        #expect(warned)
        // A program that is not named workbench (the app's own binary) is not compared.
        let app = env.workbench.deletingLastPathComponent().appendingPathComponent("WorkbenchApp")
        try FileManager.default.copyItem(at: env.workbench, to: app)
        let notCli = lines(await env.service(workbench: app).status())
        #expect(notCli.contains { $0.hasPrefix("ok: binary:") })
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: env.paths.binary.path)
        let notExecutable = lines(await env.service().status())
        #expect(notExecutable.contains { $0.hasPrefix("fail: binary: the copy the launcher runs is missing") })
        try FileManager.default.removeItem(at: env.paths.binary)
        let missing = lines(await env.service().status())
        #expect(missing.contains("fail: binary: the copy the launcher runs is missing: workbench task timer install"))
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
        let on = "warn: FileVault is on: after a restart the Mac waits for your password; the timer starts at login"
        #expect(text.contains(on))
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

    @Test func aWakeOnTheWrongDaysIsCaughtWhateverWordsPmsetUses() async throws {
        let env = try Env(front: "at: 04:00\ndays: mon,wed\nfix: pr")
        _ = try await env.service().install()
        func wake(_ days: String) async -> [String] {
            lines(await env.service(sched: "Repeating power events:\n  wakepoweron at 3:55AM \(days)\n").status())
        }
        let tuesday = await wake("Tue")
        let fixLine = "run: sudo pmset repeat wakeorpoweron MW 03:55:00"
        #expect(tuesday.contains("warn: wake: set for Tue, the tasks need MW; \(fixLine)"))
        #expect(await wake("Mon Wed").contains("ok: wake: 03:55 Mon Wed"))
        #expect(await wake("Monday, Wednesday").contains { $0.hasPrefix("ok: wake: 03:55") })
        let everyDay = await wake("every day")
        #expect(everyDay.contains { $0.hasPrefix("warn: wake: set for every day, the tasks need MW") })
        let strange = await wake("whenever")
        #expect(strange.contains { $0.hasPrefix("warn: wake: the days \"whenever\" could not be read; the tasks need MW") })
    }

    @Test func probesThatFailAreSaidNotSkipped() async throws {
        let env = try Env()
        _ = try await env.service().install()
        let text = lines(await env.service(sched: nil, power: nil, vault: nil).status())
        #expect(text.contains { $0.hasPrefix("warn: wake: could not read the wake schedule (pmset -g sched)") })
        #expect(text.contains("warn: power: could not be read (pmset -g ps); plug the Mac in"))
        #expect(text.contains { $0.hasPrefix("warn: FileVault: could not be read (fdesetup status)") })
    }

    @Test func statusOnASystemWithNoLaunchdGivesTheCronLine() async throws {
        let env = try Env()
        let text = lines(await env.service(launchd: false).status())
        let prefix = "warn: agent: this system has no launchd, so the timer is a crontab line you add yourself: */15 * * * * cd '"
        #expect(text.contains { $0.hasPrefix(prefix) })
        // No launchd also means no pmset to read: no complaints about probes it cannot run.
        #expect(!text.contains { $0.contains("could not be read") })
    }

    @Test func aTaskWithNoScheduleIsFlaggedBecauseATickNeverRunsIt() async throws {
        let env = try Env(front: "fix: report")
        try await env.task.library.approve(env.task.name)
        _ = try await env.service().install()
        let text = lines(await env.service().status())
        #expect(text.contains { $0.hasPrefix("warn: task bump: approved but has no schedule") })
    }
}
