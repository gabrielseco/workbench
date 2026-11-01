import Foundation
import WorkbenchCore

extension Commands {
    /// `task timer install | status | remove`: the launchd agent that ticks this project's scheduled tasks.
    static func taskTimer(_ a: inout Arguments) async throws -> Int32 {
        let usage = "usage: workbench task timer install [--every <5m..1h>] [--pull-main] | status | remove"
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

    /// The service for this project, with the machine's real launchd (or the stand-in a test names), this user's home and this binary.
    static func timerService() async throws -> TimerService {
        let ctx = try await Context.load()
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
