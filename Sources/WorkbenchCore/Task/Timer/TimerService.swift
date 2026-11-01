import Foundation

public enum TimerError: Error, Equatable, Sendable, CustomStringConvertible {
    /// No launchd on this system: the line to put in a crontab instead.
    case noLaunchd(cron: String, note: String?)
    case badInterval(String)
    case launchctlFailed(String, String)
    case cannotWrite(String)

    public var description: String {
        switch self {
        case .noLaunchd(let cron, let note):
            "this system has no launchd; add this line to your crontab instead (crontab -e): \(cron)"
                + (note.map { " (\($0))" } ?? "")
        case .badInterval(let value): "'\(value)' is not an interval from 5m to 1h"
        case .launchctlFailed(let what, let why): "launchctl \(what) failed: \(why)"
        case .cannotWrite(let why): "the timer could not be written: \(why)"
        }
    }
}

/// What the machine says about itself. Read only; each can be replaced in a test.
public struct TimerProbes: Sendable {
    /// `pmset -g sched`.
    public var sched: @Sendable () async -> String?
    /// The first line of `pmset -g ps`: `Now drawing from 'AC Power'`.
    public var power: @Sendable () async -> String?
    /// `fdesetup status`: `FileVault is On.`
    public var fileVault: @Sendable () async -> String?

    public init(
        sched: @escaping @Sendable () async -> String?, power: @escaping @Sendable () async -> String?,
        fileVault: @escaping @Sendable () async -> String?
    ) {
        (self.sched, self.power, self.fileVault) = (sched, power, fileVault)
    }

    /// The real commands, where they exist (macOS).
    public static let system = TimerProbes(
        sched: { await run("/usr/bin/pmset", ["-g", "sched"]) },
        power: { await run("/usr/bin/pmset", ["-g", "ps"]).flatMap { $0.split(separator: "\n").first.map(String.init) } },
        fileVault: { await run("/usr/bin/fdesetup", ["status"]) })

    static func run(_ path: String, _ arguments: [String]) async -> String? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let runner = GitRunner(executable: URL(fileURLWithPath: path), environment: ["PATH": "/usr/bin:/bin"], timeout: 10)
        guard let result = try? await runner.run(arguments, in: URL(fileURLWithPath: "/")), result.succeeded else { return nil }
        return result.stdout
    }
}

public struct TimerStatusLine: Sendable, Equatable {
    public enum Level: String, Sendable { case ok, warn, fail }
    public var level: Level
    public var text: String
}

/// `workbench task timer`: the launchd agent that ticks a project's tasks, the launcher it runs and what the machine needs besides.
/// It writes two files and runs `launchctl`; it never runs `sudo` or changes a power setting: it says the line.
public struct TimerService: Sendable {
    public let project: Project
    public let paths: TimerPaths
    public let workbench: URL
    /// Nil on a system without launchd.
    public let launchctl: GitRunner?
    public let uid: UInt32
    public var probes: TimerProbes
    public var now: @Sendable () -> Date = { Date() }

    public init(
        project: Project, home: URL, workbench: URL, launchctl: GitRunner?, uid: UInt32, probes: TimerProbes = .system
    ) {
        self.project = project
        self.paths = TimerPaths(project: project, home: home)
        self.workbench = workbench
        self.launchctl = launchctl
        self.uid = uid
        self.probes = probes
    }

    private var domain: String { "gui/\(uid)" }
    private var target: String { "gui/\(uid)/\(paths.label)" }

    private func tasks() -> [TaskDefinition] {
        let library = TaskLibrary(project: project)
        return library.names().compactMap { try? library.load($0).definition }
    }

    public static func interval(_ text: String) throws -> Int {
        guard let match = text.wholeMatch(of: #/([0-9]+)([mh])/#), let n = Int(match.1), n <= TimerFiles.maximumInterval else {
            throw TimerError.badInterval(text)
        }
        let seconds = n * (match.2 == "h" ? 3600 : 60)
        guard (TimerFiles.minimumInterval...TimerFiles.maximumInterval).contains(seconds) else {
            throw TimerError.badInterval(text)
        }
        return seconds
    }

    // MARK: install

    /// Writes the launcher and the agent, loads it, and returns what to tell the person. Safe to run again: it replaces what it wrote.
    public func install(interval: Int = TimerFiles.defaultInterval, pullMain: Bool = false) async throws -> [String] {
        guard let launchctl else {
            let cron = TimerFiles.cron(project: project, workbench: workbench, interval: interval)
            throw TimerError.noLaunchd(cron: cron.line, note: cron.note)
        }
        let fm = FileManager.default
        do {
            let directories = [
                paths.launcherDirectory, paths.plist.deletingLastPathComponent(), paths.log.deletingLastPathComponent(),
            ]
            for directory in directories { try fm.createDirectory(at: directory, withIntermediateDirectories: true) }
            try TimerFiles.launcher(project: project, workbench: workbench, label: paths.label, pullMain: pullMain)
                .write(to: paths.launcher, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.launcher.path)
            try TimerFiles.plist(paths: paths, project: project, interval: interval)
                .write(to: paths.plist, atomically: true, encoding: .utf8)
        } catch { throw TimerError.cannotWrite("\(error)") }

        // Load it afresh: an agent already loaded under this name is unloaded first, so a second install takes the new files.
        _ = try? await launchctl.run(["bootout", target], in: paths.home)
        let loaded = try? await launchctl.run(["bootstrap", domain, paths.plist.path], in: paths.home)
        guard let loaded, loaded.succeeded else {
            let why = loaded.map { $0.stderr.trimmingCharacters(in: .whitespacesAndNewlines) } ?? "it could not be run"
            throw TimerError.launchctlFailed("bootstrap", why)
        }

        var lines = [
            "installed \(paths.label)",
            "  ticks every \(interval / 60) minutes; the tasks' own schedules say what is due",
            "  launcher: \(paths.launcher.path)",
            "  log:      \(paths.log.path)",
        ]
        if workbench.path.contains("/.build/debug/") {
            lines.append("note: it runs \(workbench.path); a rebuild replaces that file, so rebuild when no tick is running")
        }
        switch TimerWake.plan(for: tasks()) {
        case .wake(let time, let days):
            let plan = TimerWake.Plan.wake(time: time, days: days)
            lines.append("to wake the Mac for them, run this yourself (it needs your password; Workbench does not run sudo):")
            lines.append("  \(plan.command ?? "")")
        case .none(let reason):
            lines.append("no wake schedule: \(reason)")
        }
        lines.append("also: keep the Mac plugged in and logged in (a restart with FileVault waits for your password)")
        lines.append("check it any time with: workbench task timer status")
        return lines
    }

    // MARK: remove

    /// What `remove` did, and whether it did all of it: an agent that could not be unloaded, or a file that could not be deleted, is not
    /// "removed".
    public struct RemoveResult: Sendable, Equatable {
        public var lines: [String]
        public var ok: Bool
    }

    public func remove() async -> RemoveResult {
        let fm = FileManager.default
        var lines: [String] = []
        var ok = true
        guard let launchctl else {
            return RemoveResult(
                lines: [
                    "this system has no launchd: Workbench installed nothing here; remove the crontab line you added (crontab -e)"
                ], ok: true)
        }
        if let result = try? await launchctl.run(["bootout", target], in: paths.home) {
            if result.succeeded {
                lines.append("unloaded \(paths.label)")
            } else if !Self.notLoaded(result) {
                // The agent is still there: keep its files, so what runs and what is on disk agree.
                let why = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                return RemoveResult(
                    lines: [
                        "could not unload \(paths.label): \(why)", "nothing was deleted; try: launchctl bootout \(target)",
                    ], ok: false)
            }
        }
        for file in [paths.plist, paths.launcher] where fm.fileExists(atPath: file.path) {
            do {
                try fm.removeItem(at: file)
                lines.append("removed \(file.path)")
            } catch {
                ok = false
                lines.append("could not delete \(file.path): \(error.localizedDescription)")
            }
        }
        if ok { try? fm.removeItem(at: paths.launcherDirectory) }
        if lines.isEmpty { lines.append("no timer was installed for this project") }
        lines.append("the log is left at \(paths.log.path)")
        lines.append("if you set a wake schedule for it: sudo pmset repeat cancel")
        return RemoveResult(lines: lines, ok: ok)
    }

    /// `launchctl bootout` of an agent that is not loaded: not a failure, there was nothing to unload.
    static func notLoaded(_ result: GitResult) -> Bool {
        result.status == 3 || result.status == 113 || result.stderr.contains("No such process")
            || result.stderr.contains("Could not find service") || result.stderr.contains("no such service")
    }

    // MARK: status

    public func status() async -> [TimerStatusLine] {
        var out: [TimerStatusLine] = []
        func add(_ level: TimerStatusLine.Level, _ text: String) { out.append(TimerStatusLine(level: level, text: text)) }

        // The agent.
        let installed = FileManager.default.fileExists(atPath: paths.plist.path)
        if launchctl == nil {
            let cron = TimerFiles.cron(project: project, workbench: workbench, interval: TimerFiles.defaultInterval)
            add(.warn, "agent: this system has no launchd, so the timer is a crontab line you add yourself: \(cron.line)")
        } else if !installed {
            add(.fail, "agent: not installed: workbench task timer install")
        } else if let launchctl, let printed = try? await launchctl.run(["print", target], in: paths.home), printed.succeeded {
            let text = printed.stdout
            let runs = text.firstMatch(of: #/runs = ([0-9]+)/#).map { String($0.1) } ?? "?"
            let exit = text.firstMatch(of: #/last exit code = ([0-9]+)/#).map { String($0.1) }
            let interval = text.firstMatch(of: #/run interval = ([0-9]+) seconds/#).map { String($0.1) }
            let every = interval.flatMap(Int.init).map { "every \($0 / 60) min" } ?? "on an interval"
            add(.ok, "agent: loaded, \(every), ran \(runs) time(s)" + (exit.map { ", last exit code \($0)" } ?? ""))
            if let exit, exit != "0" { add(.warn, "the last tick exited \(exit): see \(paths.log.path)") }
        } else {
            add(.fail, "agent: installed but not loaded: workbench task timer install (it loads it again)")
        }
        if let modified = (try? FileManager.default.attributesOfItem(atPath: paths.log.path))?[.modificationDate] as? Date {
            let format = DateFormatter()
            format.locale = Locale(identifier: "en_US_POSIX")
            format.dateFormat = "yyyy-MM-dd HH:mm"
            add(.ok, "last tick: \(format.string(from: modified)) (\(paths.log.path))")
        } else if installed {
            add(.warn, "last tick: none yet (the first one comes within the interval)")
        }

        // The tasks.
        let library = TaskLibrary(project: project)
        let defined = library.names().compactMap { name in (name, try? library.load(name).definition) }
        if defined.isEmpty { add(.warn, "tasks: none in .workbench/tasks (workbench task new <name>)") }
        for name in library.names() {
            let summary = library.summary(name)
            if let problem = summary.problem {
                add(.fail, "task \(name): cannot be loaded: \(TaskExplanation.clean(problem, limit: 160))")
            } else if summary.approval != .approved {
                let state = summary.approval == .stale ? "STALE" : "not approved"
                add(.warn, "task \(name): \(state): workbench task approve \(name)")
            } else if summary.schedule == nil {
                add(.warn, "task \(name): approved but has no schedule (at:/every:), so a tick never runs it")
            } else {
                add(.ok, "task \(name): approved, \(summary.schedule ?? "")")
            }
        }

        // The machine.
        let plan = TimerWake.plan(for: defined.compactMap(\.1))
        let rawSched = await probes.sched()
        let canProbe = launchctl != nil
        out.append(wakeStatus(plan: plan, rawSched: rawSched, canProbe: canProbe))
        if let power = await probes.power() {
            if power.contains("Battery") {
                add(.warn, "power: on battery; plug in so a run is not cut short")
            } else {
                add(.ok, "power: \(power.contains("AC") ? "plugged in" : power)")
            }
        } else if canProbe {
            add(.warn, "power: could not be read (pmset -g ps); plug the Mac in")
        }
        if let vault = await probes.fileVault() {
            if vault.contains("FileVault is On") {
                add(.warn, "FileVault is on: after a restart nothing runs until you log in")
            } else {
                add(.ok, "FileVault is off: the timer survives a restart")
            }
        } else if canProbe {
            add(.warn, "FileVault: could not be read (fdesetup status); if it is on, a restart waits for your login")
        }
        return out
    }

    /// Whether the machine's repeating wake is what the tasks need: the same time, and the same days read as a set, never "close enough".
    private func wakeStatus(plan: TimerWake.Plan, rawSched: String?, canProbe: Bool) -> TimerStatusLine {
        func line(_ level: TimerStatusLine.Level, _ text: String) -> TimerStatusLine { TimerStatusLine(level: level, text: text) }
        guard case .wake(let time, let days) = plan else {
            if case .none(let reason) = plan { return line(.ok, "wake: not needed (\(reason))") }
            return line(.ok, "wake: not needed")
        }
        let fix = "run: \(plan.command ?? "")"
        if rawSched == nil, canProbe {
            return line(.warn, "wake: could not read the wake schedule (pmset -g sched); expected: \(plan.command ?? "")")
        }
        guard let set = rawSched.flatMap(TimerWake.parseRepeating) else {
            return line(.warn, "wake: no repeating wake is set; \(fix)")
        }
        if set.time != time {
            return line(.warn, "wake: set for \(set.time.text), the tasks need \(time.text); \(fix)")
        }
        guard let setDays = TimerWake.parseDays(set.days) else {
            let need = TimerWake.letters(days)
            return line(.warn, "wake: the days \"\(set.days)\" could not be read; the tasks need \(need); \(fix)")
        }
        guard setDays == days else {
            let need = TimerWake.pmsetWording(days) ?? TimerWake.letters(days)
            return line(.warn, "wake: set for \(set.days), the tasks need \(need); \(fix)")
        }
        return line(.ok, "wake: \(time.text) \(set.days)")
    }
}
