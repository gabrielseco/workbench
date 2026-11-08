import Foundation
import WorkbenchCore

extension Commands {
    static func config(_ arguments: [String]) async throws {
        switch arguments.first {
        case nil: break
        case "set": return try await configEdit(Array(arguments.dropFirst()), setting: true)
        case "unset": return try await configEdit(Array(arguments.dropFirst()), setting: false)
        default: throw CLIError.usage("config takes no argument, or set <key> <value>, or unset <key>. ")
        }
        let ctx = try await Context.load()
        let config = try Config.load(from: ctx.project.configURL)
        let invocation = try config.previewInvocation()
        let env = ProcessInfo.processInfo.environment
        let resolved = ExecutableResolver.resolve(config.claudePath, searchPath: env["PATH"])
        out("config:   \(ctx.project.configURL.path)")
        out("claude:   \(resolved?.path ?? "NOT FOUND on PATH (\(config.claudePath))")")
        out("check:    \(config.checkCommand ?? "(none)")")
        out("budget:   \(config.defaultBudgetUSD) USD default")
        out("perms:    \(config.permissions.rawValue)")
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

extension Commands {
    /// `config set <key> <value>` and `config unset <key>`: one agent key, written by `ConfigEdit`.
    static func configEdit(_ arguments: [String], setting: Bool) async throws {
        let usage = setting ? "usage: workbench config set <key> <value>" : "usage: workbench config unset <key>"
        guard arguments.count == (setting ? 2 : 1) else { throw CLIError.usage(usage) }
        let ctx = try await Context.load()
        do {
            let key = try ConfigEdit.parseKey(arguments[0])
            let change =
                setting
                ? try ConfigEdit.set(key, to: arguments[1], in: ctx.project) : try ConfigEdit.unset(key, in: ctx.project)
            let was = change.old ?? "(not set)"
            let now = change.new ?? "(not set)"
            out(change.written ? "\(key): \(was) -> \(now)" : "\(key): already \(now), nothing written")
            if change.written, key.role == .run, case let active = ctx.store.activeThreadIDs(), !active.isEmpty {
                out(
                    "note: thread \(active.joined(separator: ", ")) may have been approved for the old run settings: "
                        + "`workbench run` refuses until "
                        + "`workbench goal approve` binds the new ones")
            }
        } catch let failure as ConfigEdit.Failure {
            throw CLIError.refused("\(failure)")
        }
    }
}
