import Foundation
import WorkbenchCore

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

let arguments = Array(CommandLine.arguments.dropFirst())

switch arguments.first {
case "--version", "version":
    print("workbench \(Workbench.version)")

case "config":
    // Prints what a turn would run, so the tool set can be inspected without spawning anything.
    let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(".workbench/config.toml")
    do {
        let config = try Config.load(from: url)
        let turn = TurnRequest(
            sessionID: UUID(), resume: false, budgetUSD: config.defaultBudgetUSD, prompt: "<prompt>")
        let invocation = try config.invocation(for: turn)
        let resolved = ExecutableResolver.resolve(
            config.claudePath, searchPath: ProcessInfo.processInfo.environment["PATH"])
        print("config:   \(url.path)")
        print("claude:   \(resolved?.path ?? "NOT FOUND on PATH (\(config.claudePath))")")
        print("check:    \(config.checkCommand ?? "(none)")")
        print("budget:   \(config.defaultBudgetUSD) USD default")
        print("tools:    \(config.tools.available.joined(separator: ", "))")
        print("allowed:  \(config.effectiveAllowedTools.joined(separator: ", "))")
        print("denied:   \(config.tools.denied.joined(separator: ", "))")
        print("env:      \(config.childEnvironment(from: ProcessInfo.processInfo.environment).keys.sorted().joined(separator: ", "))")
        print("command:  \(invocation.displayCommand)")
    } catch let error as ConfigError {
        fail("workbench: invalid config\n\(error)", code: 2)
    } catch {
        fail("workbench: \(error)")
    }

case nil, "--help", "help":
    print("""
    usage: workbench <command>

    commands:
      version    print the version
      config     show the resolved config and the command a turn would run
    """)

default:
    fail("workbench: unknown command '\(arguments[0])'", code: 2)
}
