import Foundation
import WorkbenchCore

extension Commands {
    /// `task timer install | status | remove`: the launchd agent that ticks this project's scheduled tasks.
    static func taskTimer(_ a: inout Arguments) async throws -> Int32 {
        let usage = "usage: workbench task timer install [--every <5m..1h>] [--pull-main] | refresh [--all] | status | remove"
        guard let verb = a.positional() else { throw CLIError.usage(usage) }
        switch verb {
        case "install":
            let every = try a.value("--every")
            let pull = a.flag("--pull-main")
            try a.requireEmpty()
            let seconds: Int
            do { seconds = try every.map { try TimerService.interval($0) } ?? TimerFiles.defaultInterval } catch {
                throw CLIError.usage("\(error)")
            }
            let service = try await timerService()
            do {
                for line in try await service.install(interval: seconds, pullMain: pull) { out(line) }
            } catch let error as TimerError {
                throw CLIError.refused("\(error)")
            }
            return 0
        case "refresh":
            let all = a.flag("--all")
            try a.requireEmpty()
            return try await taskTimerRefresh(all: all)
        case "status":
            try a.requireEmpty()
            let status = await (try await timerService()).status()
            for line in status {
                let mark = ["ok": "ok   ", "warn": "warn ", "fail": "FAIL "][line.level.rawValue] ?? ""
                out(mark + line.text)
            }
            return status.contains { $0.level == .fail } ? 1 : 0
        case "remove":
            try a.requireEmpty()
            let result = await (try await timerService()).remove()
            for line in result.lines { out(line) }
            return result.ok ? 0 : 1
        default:
            throw CLIError.usage("unknown timer command '\(verb)'. \(usage)")
        }
    }

    /// `task timer refresh [--all]`: bring the installed timer (every installed timer, with --all) up to date with this binary. `--all`
    /// is what the post-merge hook runs, from any folder. A timer whose project is gone is said out loud and fails the pass.
    private static func taskTimerRefresh(all: Bool) async throws -> Int32 {
        guard all else {
            let result = try await refreshing(timerService())
            for line in result.lines { out(line) }
            return result.outcome == .notInstalled ? 1 : 0
        }
        let env = ProcessInfo.processInfo.environment
        let home = URL(fileURLWithPath: env["HOME"] ?? NSHomeDirectory(), isDirectory: true)
        let entries = TimerRegistry.projects(home: home)
        guard !entries.isEmpty else {
            out("no project has a timer installed (workbench task timer install, in the project)")
            return 0
        }
        var code: Int32 = 0
        for entry in entries {
            let loaded = FileManager.default.fileExists(atPath: entry.root.path) ? try? await Context.load(at: entry.root) : nil
            guard let ctx = loaded, entry.isTheProject(ctx.project) else {
                out("PROBLEM  \(entry.root.path) is gone or is not a repository: workbench task timer remove, in that project")
                code = 1
                continue
            }
            do {
                for line in try await timerService(ctx).refresh().lines { out(line) }
            } catch let error as TimerError {
                out("PROBLEM  \(entry.root.lastPathComponent): \(error)")
                code = 1
            }
        }
        return code
    }

    private static func refreshing(_ service: TimerService) async throws -> TimerService.RefreshResult {
        do { return try await service.refresh() } catch let error as TimerError { throw CLIError.refused("\(error)") }
    }

    /// The service for this project, with the machine's real launchd (or the stand-in a test names), this user's home and this binary.
    static func timerService() async throws -> TimerService { try await timerService(Context.load()) }

    static func timerService(_ ctx: Context) -> TimerService {
        let env = ProcessInfo.processInfo.environment
        let home = URL(fileURLWithPath: env["HOME"] ?? NSHomeDirectory(), isDirectory: true)
        #if os(macOS)
        let launchctlPath: String? = env["WORKBENCH_LAUNCHCTL"] ?? "/bin/launchctl"
        #else
        let launchctlPath: String? = env["WORKBENCH_LAUNCHCTL"]
        #endif
        let launchctl = launchctlPath.flatMap { path -> GitRunner? in
            guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
            return GitRunner(executable: URL(fileURLWithPath: path), environment: ["PATH": "/usr/bin:/bin"], timeout: 30)
        }
        let binary = Bundle.main.executableURL?.resolvingSymlinksInPath() ?? URL(fileURLWithPath: CommandLine.arguments[0])
        return TimerService(project: ctx.project, home: home, workbench: binary, launchctl: launchctl, uid: getuid())
    }
}
