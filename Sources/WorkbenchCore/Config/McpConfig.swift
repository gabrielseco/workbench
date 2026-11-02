import Foundation

/// One `[mcp_servers.<name>]` table: a server a task may load for its own runs (`mcp_tools` in task.md). It holds no secret: a
/// remote server's login is the one the user already did in their own `claude`, found through `CLAUDE_CONFIG_DIR`.
public struct McpServer: Sendable, Equatable {
    public enum Transport: String, Sendable, Equatable { case stdio, http, sse }

    public var name: String
    public var transport: Transport
    /// `http` and `sse`: the server's address.
    public var url: String?
    /// `stdio`: the program and its arguments.
    public var command: String?
    public var args: [String] = []

    public init(
        name: String, transport: Transport, url: String? = nil, command: String? = nil,
        args: [String] = []
    ) {
        (self.name, self.transport, self.url, self.command, self.args) = (
            name, transport, url, command, args
        )
    }

    static let tablePrefix = "mcp_servers."
    static let keys: Set<String> = ["type", "url", "command", "args"]
    public static let maxServers = 10
    public static let maxArgs = 20

    static func owns(table name: String) -> Bool { name.hasPrefix(tablePrefix) }

    /// The strings of an array value, nil when it holds anything else or more than `limit` items.
    private static func stringArray(_ value: TOMLValue, limit: Int) -> [String]? {
        guard case .array(let items) = value, items.count <= limit else { return nil }
        var out: [String] = []
        for item in items {
            guard case .string(let s) = item, !s.contains("\0") else { return nil }
            out.append(s)
        }
        return out
    }

    /// The server entry of the JSON file `--mcp-config` reads.
    var jsonEntry: [String: Any] {
        switch transport {
        case .stdio: ["type": "stdio", "command": command ?? "", "args": args]
        case .http, .sse: ["type": transport.rawValue, "url": url ?? ""]
        }
    }

    /// Every `[mcp_servers.<name>]` table, by name. A table with a problem is reported through `fail` and left out.
    static func parse(_ document: TOMLDocument, fail: ReviewConfig.Fail) -> [String: McpServer] {
        var servers: [String: McpServer] = [:]
        let tables = document.tables.filter { owns(table: $0.key) }.sorted { $0.key < $1.key }
        if tables.count > maxServers {
            fail(
                .invalidValue, tables[maxServers].value.line,
                "more than \(maxServers) [mcp_servers.*] tables")
        }
        for (full, table) in tables {
            let name = String(full.dropFirst(tablePrefix.count))
            guard McpTool.isServerName(name) else {
                fail(
                    .invalidValue, table.line,
                    "[\(full)]: '\(name)' is not a usable server name (letters and digits, with - or _ between)"
                )
                continue
            }
            var ok = true
            for (key, entry) in table.entries.sorted(by: { $0.key < $1.key }) where !keys.contains(key) {
                fail(.unknownKey, entry.line, "unknown key '\(key)' in [\(full)]")
                ok = false
            }
            func string(_ key: String) -> String? {
                guard let entry = table.entries[key] else { return nil }
                guard case .string(let value) = entry.value, !value.isEmpty, !value.contains("\n"),
                    !value.contains("\0")
                else {
                    fail(.wrongType, entry.line, "'\(key)' in [\(full)] must be a non-empty string")
                    ok = false
                    return nil
                }
                return value
            }
            var transport = Transport.stdio
            if let value = string("type") {
                if let parsed = Transport(rawValue: value) {
                    transport = parsed
                } else {
                    fail(
                        .invalidValue, table.entries["type"]?.line ?? table.line,
                        "'type' in [\(full)] must be \"stdio\", \"http\" or \"sse\"")
                    continue
                }
            } else if table.entries["type"] == nil, table.entries["url"] != nil {
                transport = .http
            }
            let url = string("url")
            let command = string("command")
            var args: [String] = []
            if let entry = table.entries["args"] {
                if let strings = stringArray(entry.value, limit: maxArgs) {
                    args = strings
                } else {
                    fail(
                        .wrongType, entry.line,
                        "'args' in [\(full)] must be an array of at most \(maxArgs) strings")
                    ok = false
                }
            }
            switch transport {
            case .stdio:
                if command == nil {
                    fail(.missingKey, table.line, "[\(full)] needs 'command' (type stdio)")
                    ok = false
                }
                if url != nil {
                    fail(.conflict, table.line, "[\(full)] is stdio: 'url' belongs to type http or sse")
                    ok = false
                }
            case .http, .sse:
                if let url, let parsed = URL(string: url), parsed.scheme == "https", parsed.host != nil {
                } else {
                    fail(
                        .invalidValue, table.line,
                        "[\(full)] needs 'url' as an https address (type \(transport.rawValue))")
                    ok = false
                }
                if command != nil || !args.isEmpty {
                    fail(
                        .conflict, table.line,
                        "[\(full)] is \(transport.rawValue): 'command' and 'args' belong to type stdio")
                    ok = false
                }
            }
            if ok {
                servers[name] = McpServer(
                    name: name, transport: transport, url: url, command: command, args: args)
            }
        }
        return servers
    }
}

/// A tool name as `claude` has it for an MCP server: `mcp__<server>__<tool>`, exactly, with no wildcard.
public enum McpTool {
    public static let maxTools = 10
    public static let maxLength = 100

    /// Letters and digits, with a single `-` or `_` between them: so `__` never appears inside a server name.
    public static func isServerName(_ s: String) -> Bool {
        s.count <= 40
            && s.range(of: #"\A[A-Za-z0-9]+([_-][A-Za-z0-9]+)*\z"#, options: .regularExpression) != nil
    }

    /// The server and the tool, nil when the name is not shaped `mcp__<server>__<tool>`.
    public static func split(_ name: String) -> (server: String, tool: String)? {
        guard name.count <= maxLength, name.hasPrefix("mcp__") else { return nil }
        let rest = name.dropFirst("mcp__".count)
        guard let range = rest.range(of: "__") else { return nil }
        let server = String(rest[..<range.lowerBound])
        let tool = String(rest[range.upperBound...])
        guard isServerName(server),
            tool.range(of: #"\A[A-Za-z0-9_-]+\z"#, options: .regularExpression) != nil
        else { return nil }
        return (server, tool)
    }

    /// The servers a list of tools belongs to, each once, in order.
    public static func servers(of tools: [String]) -> [String] {
        var seen: [String] = []
        for tool in tools {
            if let server = split(tool)?.server, !seen.contains(server) { seen.append(server) }
        }
        return seen
    }
}

/// What one turn of a task gets: the tools it may call and the file `--mcp-config` reads. Made for a turn, deleted after it.
public struct McpAccess: Sendable, Equatable {
    public var tools: [String]
    public var configFile: URL

    public init(tools: [String], configFile: URL) {
        self.tools = tools
        self.configFile = configFile
    }

    /// Why the servers behind `tools` cannot be loaded, nil when each has a `[mcp_servers.<name>]` table.
    public static func problem(tools: [String], servers: [String: McpServer]) -> String? {
        let missing = McpTool.servers(of: tools).filter { servers[$0] == nil }
        guard !missing.isEmpty else { return nil }
        let names = missing.map { "'\($0)'" }.joined(separator: ", ")
        return
            "mcp_tools names \(missing.count == 1 ? "server" : "servers") \(names) with no [mcp_servers.<name>] table in "
            + ".workbench/config.toml"
    }

    /// Writes a file holding only the servers `tools` need, readable by this user alone. Throws when a server has no table.
    public static func write(tools: [String], servers: [String: McpServer], in dir: URL) throws -> McpAccess {
        if let why = problem(tools: tools, servers: servers) { throw McpError.undefinedServer(why) }
        var entries: [String: Any] = [:]
        for name in McpTool.servers(of: tools) { entries[name] = servers[name]?.jsonEntry }
        let data = try JSONSerialization.data(
            withJSONObject: ["mcpServers": entries], options: [.sortedKeys])
        let file = dir.appendingPathComponent("workbench-mcp-\(UUID().uuidString).json")
        guard
            FileManager.default.createFile(
                atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600])
        else {
            throw McpError.cannotWrite(file.path)
        }
        return McpAccess(tools: tools, configFile: file)
    }

    public func remove() { try? FileManager.default.removeItem(at: configFile) }
}

public enum McpError: Error, Equatable, CustomStringConvertible {
    case undefinedServer(String)
    case cannotWrite(String)
    case unsupportedProvider

    public var description: String {
        switch self {
        case .undefinedServer(let why): why
        case .cannotWrite(let path): "the MCP config file could not be written: \(path)"
        case .unsupportedProvider:
            "mcp_tools needs Claude as the coding agent; [agents.run] names another provider"
        }
    }
}

/// `threads/<id>/mcp_tools.json`: the tools a task's thread may call, written by the task run from the approved task file and read by
/// each turn. Only tool names: the servers come from the config every time. A thread without the file has no MCP tools.
public enum McpToolsFile {
    /// Ten tool names of at most 100 characters each fit well inside this.
    static let maxFileBytes = 4096

    public static func write(_ tools: [String], project: Project, thread: String) throws {
        let data = try JSONSerialization.data(withJSONObject: ["tools": tools], options: [.sortedKeys])
        try data.write(to: project.mcpToolsURL(thread), options: .atomic)
    }

    /// Empty when the thread has no file. A file that cannot be read, or names something not shaped like a tool, throws: a damaged
    /// grant is never read as "none" or as a wider one.
    public static func read(project: Project, thread: String) throws -> [String] {
        let url = project.mcpToolsURL(thread)
        // Looked at before it is opened: a pipe would block the runner and a huge file would be read whole.
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return [] }
        guard attributes[.type] as? FileAttributeType == .typeRegular, (attributes[.size] as? Int ?? .max) <= maxFileBytes,
            let data = try? Data(contentsOf: url),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tools = object["tools"] as? [String], tools.count <= McpTool.maxTools,
            tools.allSatisfy({ McpTool.split($0) != nil })
        else { throw McpError.cannotWrite(url.path + " is damaged") }
        return tools
    }
}
