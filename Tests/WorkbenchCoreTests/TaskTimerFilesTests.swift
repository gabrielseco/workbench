import Foundation
import Testing

@testable import WorkbenchCore

struct TaskTimerFilesTests {
    private func project(_ folder: String) -> Project {
        Project(root: URL(fileURLWithPath: "/tmp/wb-timer-tests").appendingPathComponent(folder))
    }

    private let home = URL(fileURLWithPath: "/Users/someone")
    private let workbench = URL(fileURLWithPath: "/opt/wb/workbench")
    private let hostile = "we ird & <dir> \"q\" 'it' $HOME `x`"

    @Test func theNameIsStableCleanAndSeparatesProjectsWithOneName() {
        let one = TimerPaths(project: project("remote-flows"), home: home)
        let again = TimerPaths(project: project("remote-flows"), home: home)
        let other = TimerPaths(project: Project(root: URL(fileURLWithPath: "/elsewhere/remote-flows")), home: home)
        #expect(one == again && one.slug != other.slug)
        #expect(one.label == "com.workbench.task-tick.\(one.slug)" && one.slug.hasPrefix("remote-flows-"))
        let odd = TimerPaths(project: project(hostile), home: home)
        #expect(odd.slug.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
        let bare = TimerPaths(project: project("!!!"), home: home)
        #expect(bare.slug.hasPrefix("project-"))
        #expect(one.plist.path == "/Users/someone/Library/LaunchAgents/\(one.label).plist")
        #expect(one.launcher.path == "/Users/someone/.workbench/timers/\(one.slug)/tick.sh")
    }

    @Test func theAgentFileIsValidForAnyProjectPath() throws {
        let project = project(hostile)
        let paths = TimerPaths(project: project, home: home)
        let text = TimerFiles.plist(paths: paths, project: project, interval: 900)
        let object = try PropertyListSerialization.propertyList(from: Data(text.utf8), format: nil)
        let dict = try #require(object as? [String: Any])
        #expect(dict["Label"] as? String == paths.label)
        #expect(dict["ProgramArguments"] as? [String] == [paths.launcher.path])
        #expect(dict["WorkingDirectory"] as? String == project.root.path)
        #expect(dict["StartInterval"] as? Int == 900 && dict["RunAtLoad"] as? Bool == false)
        #expect(dict["StandardOutPath"] as? String == paths.log.path)
    }

    @Test func theLauncherQuotesTheProjectAndTheBinary() {
        let project = project("it's here")
        let binary = URL(fileURLWithPath: "/opt/it's/wb")
        let text = TimerFiles.launcher(project: project, workbench: binary, label: "l", pullMain: false)
        #expect(text.contains("cd '/tmp/wb-timer-tests/it'\\''s here' || exit 1"))
        #expect(text.contains("exec /usr/bin/caffeinate -i '/opt/it'\\''s/wb' task tick"))
        #expect(text.contains("zsh -lic"))
        #expect(!text.contains("git pull"))
        #expect(TimerFiles.shellQuote("a$b`c\"d'e") == "'a$b`c\"d'\\''e'")
    }

    @Test func pullingMainIsOptInAndOnlyWhenSafe() {
        let text = TimerFiles.launcher(project: project("p"), workbench: workbench, label: "l", pullMain: true)
        #expect(text.contains("git rev-parse --abbrev-ref HEAD") && text.contains("git status --porcelain"))
        #expect(text.contains("git pull --ff-only"))
    }

    @Test func aSystemWithNoLaunchdGetsACronLineThatMeansWhatWasAsked() {
        let cron = TimerFiles.cron(project: project("my proj"), workbench: workbench, interval: 900)
        #expect(cron.line == "*/15 * * * * cd '/tmp/wb-timer-tests/my proj' && '/opt/wb/workbench' task tick" && cron.note == nil)
        for (seconds, expected) in [(300, "*/5"), (600, "*/10"), (1200, "*/20"), (1800, "*/30")] {
            let line = TimerFiles.cron(project: project("p"), workbench: workbench, interval: seconds).line
            #expect(line.hasPrefix("\(expected) * * * * "))
        }
        #expect(TimerFiles.cron(project: project("p"), workbench: workbench, interval: 3600).line.hasPrefix("0 * * * * "))
    }

    @Test func cronCannotRunEveryFortyFiveMinutesSoItSaysWhatItDoesInstead() {
        let cron = TimerFiles.cron(project: project("p"), workbench: workbench, interval: 2700)
        #expect(cron.line.hasPrefix("*/30 * * * * "))
        #expect(cron.note == "cron cannot run every 45 minutes; this runs every 30")
        let seven = TimerFiles.cron(project: project("p"), workbench: workbench, interval: 420)
        // Seven rounds down to six, the largest interval below it that divides the hour.
        #expect(seven.line.hasPrefix("*/6 * * * * ") && seven.note == "cron cannot run every 7 minutes; this runs every 6")
    }

    @Test func aPercentSignInAPathIsEscapedForCron() {
        let cron = TimerFiles.cron(project: project("100% sure"), workbench: workbench, interval: 900)
        #expect(cron.line.contains("100\\% sure") && !cron.line.replacingOccurrences(of: "\\%", with: "").contains("%"))
    }

    @Test func anIntervalIsFiveMinutesToAnHour() throws {
        #expect(try TimerService.interval("5m") == 300)
        #expect(try TimerService.interval("15m") == 900)
        #expect(try TimerService.interval("1h") == 3600)
        for bad in ["4m", "61m", "2h", "0m", "x", "", "15", "99999999999999999999m", "1.5h"] {
            #expect(throws: TimerError.badInterval(bad)) { try TimerService.interval(bad) }
        }
    }
}

@Suite(.processGate) struct TaskTimerLauncherSyntaxTests {
    @Test func theLauncherIsValidShellWhateverThePathIs() async throws {
        let root = try Scratch.directory("timer-launcher").appendingPathComponent("it's a \"dir\" $x `y`")
        let project = Project(root: root)
        for pull in [false, true] {
            let script = Scratch.url("tick", ext: "sh")
            let binary = URL(fileURLWithPath: "/opt/wb's/workbench")
            try TimerFiles.launcher(project: project, workbench: binary, label: "l", pullMain: pull)
                .write(to: script, atomically: true, encoding: .utf8)
            let sh = URL(fileURLWithPath: "/bin/sh")
            let runner = GitRunner(executable: sh, environment: ["PATH": "/usr/bin:/bin"], timeout: 10)
            let result = try await runner.run(["-n", script.path], in: URL(fileURLWithPath: "/"))
            #expect(result.succeeded, "pull=\(pull): \(result.stderr)")
        }
    }
}
