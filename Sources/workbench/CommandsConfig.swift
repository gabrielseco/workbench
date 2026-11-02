import Foundation
import WorkbenchCore

extension Commands {
    static func config() async throws {
        let ctx = try await Context.load()
        let config = try Config.load(from: ctx.project.configURL)
        let invocation = try config.previewInvocation()
        let env = ProcessInfo.processInfo.environment
        let resolved = ExecutableResolver.resolve(config.claudePath, searchPath: env["PATH"])
        out("config:   \(ctx.project.configURL.path)")
        out("claude:   \(resolved?.path ?? "NOT FOUND on PATH (\(config.claudePath))")")
        out("check:    \(config.checkCommand ?? "(none)")")
        out("budget:   \(config.defaultBudgetUSD) USD default")
        out("tools:    \(config.tools.available.joined(separator: ", "))")
        out("allowed:  \(config.effectiveAllowedTools.joined(separator: ", "))")
        out("denied:   \(config.tools.denied.joined(separator: ", "))")
        out("env:      \(config.childEnvironment(from: env).keys.sorted().joined(separator: ", "))")
        if !config.mcpServers.isEmpty {
            let servers = config.mcpServers.values.sorted { $0.name < $1.name }.map { server in
                "\(server.name) (\(server.transport.rawValue) \(server.url ?? server.command ?? ""))"
            }
            out(
                "mcp:      \(servers.joined(separator: ", ")) (only for tasks that list tools in mcp_tools)"
            )
        }
        let library = TaskLibrary(project: ctx.project)
        for name in library.names() {
            let tools = library.summary(name).mcpTools
            if !tools.isEmpty {
                out(
                    "mcp tools: task \(name) may call \(tools.joined(separator: ", ")); runs without --safe-mode"
                )
            }
        }
        out("command:  \(invocation.displayCommand)")
    }
}
