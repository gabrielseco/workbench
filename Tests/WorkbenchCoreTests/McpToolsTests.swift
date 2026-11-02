import Foundation
import Testing

@testable import WorkbenchCore

private let toolsTable =
    "[tools]\navailable = [\"Read\", \"Bash\"]\nallowed = [\"Read\"]\ndenied = [\"Bash(git push:*)\"]\n"
private let linear = "[mcp_servers.linear]\ntype = \"http\"\nurl = \"https://mcp.linear.app/mcp\"\n"
private let session = UUID(uuidString: "E79CF457-1714-495A-9FFE-526C12A4852E")!

private func configProblems(_ text: String) -> [String] {
    do {
        _ = try Config.parse(text)
        return []
    } catch let error as ConfigError {
        return error.problems.map(\.message)
    } catch { return ["\(error)"] }
}

private func taskProblems(_ front: String) -> [String] {
    do {
        _ = try TaskDefinition.parse("---\n\(front)\n---\nDo it.\n", name: "bump")
        return []
    } catch let error as TaskParseError {
        return error.problems.map(\.description)
    } catch { return ["\(error)"] }
}

struct McpToolNameTests {
    @Test func onlyExactToolsShapedServerDoubleUnderscoreToolAreAccepted() {
        #expect(McpTool.split("mcp__linear__get_issue")?.server == "linear")
        #expect(McpTool.split("mcp__linear__get_issue")?.tool == "get_issue")
        #expect(McpTool.split("mcp__my-server__save-issue")?.server == "my-server")
        for bad in [
            "mcp__linear", "mcp__linear__", "mcp____tool", "Bash", "mcp__linear__*", "mcp__linear__a b",
            "mcp__lin ear__a",
            "mcp__linear__a(b)", "mcp__-a__b", "mcp__linear__get_issue\n",
        ] {
            #expect(McpTool.split(bad) == nil, "\(bad) should be refused")
        }
    }
}

struct McpTaskFileTests {
    @Test func aTaskListsToolsAndWithoutTheKeyListsNone() throws {
        let set = try TaskDefinition.parse(
            "---\nfix: pr\nmcp_tools: mcp__linear__get_issue, mcp__linear__save_issue\n---\nDo it.\n",
            name: "bump")
        #expect(set.mcpTools == ["mcp__linear__get_issue", "mcp__linear__save_issue"])
        let plain = try TaskDefinition.parse("---\nfix: pr\n---\nDo it.\n", name: "bump")
        #expect(plain.mcpTools.isEmpty)
    }

    @Test func badNamesWildcardsDuplicatesAndAReportTaskAreRefusedWithTheLine() {
        #expect(taskProblems("fix: pr\nmcp_tools: Bash").first?.contains("line 3") == true)
        #expect(taskProblems("fix: pr\nmcp_tools: mcp__linear__get_issue, mcp__linear__*").count == 1)
        #expect(
            taskProblems("fix: pr\nmcp_tools: mcp__linear__get_issue, mcp__linear__get_issue").count == 1)
        #expect(taskProblems("fix: pr\nmcp_tools: ").count == 1)
        let many = (1...11).map { "mcp__s__t\($0)" }.joined(separator: ", ")
        #expect(taskProblems("fix: pr\nmcp_tools: \(many)").count == 1)
        // A report turn is read-only and always safe mode: the key is refused, not ignored.
        #expect(
            taskProblems("fix: report\nmcp_tools: mcp__linear__get_issue").first?.contains("fix: pr")
                == true)
        #expect(taskProblems("mcp_tools: mcp__linear__get_issue").count == 1)
    }

    @Test func editingTheToolsMakesTheApprovalStaleAndATaskWithoutThemKeepsItsHash() throws {
        let hash = { (front: String) throws -> String in
            TaskApproval.hash(
                task: try TaskDefinition.parse("---\n\(front)\n---\nDo it.\n", name: "bump"),
                pendingScript: nil)
        }
        let one = try hash("fix: pr\nmcp_tools: mcp__linear__get_issue")
        let two = try hash("fix: pr\nmcp_tools: mcp__linear__get_issue, mcp__linear__save_issue")
        let swapped = try hash("fix: pr\nmcp_tools: mcp__linear__save_issue, mcp__linear__get_issue")
        let plain = try hash("fix: pr")
        #expect(one != two && one != plain)
        let report = try hash("fix: report")
        #expect(two == swapped, "order is layout")
        #expect(report == "9bacf49b550487ed3675f3339586d0da47f309e3c438fe8533b0dac4fe640566")
    }

    @Test func aServerWithNoTableRefusesTheTaskAtLoadAndADefinedOneLoads() async throws {
        let fx = try TaskFixture(front: "fix: pr\nmcp_tools: mcp__linear__get_issue")
        try FileManager.default.createDirectory(
            at: fx.project.workbenchDirectory, withIntermediateDirectories: true)
        try (toolsTable).write(to: fx.project.configURL, atomically: true, encoding: .utf8)
        let library = TaskLibrary(project: fx.project)
        #expect(throws: TaskFileError.self) { try library.load(fx.name) }
        await #expect(throws: TaskFileError.self) { try await library.approve(fx.name) }
        #expect(library.summary(fx.name).problem?.contains("'linear'") == true)
        #expect(library.mcpProblems(servers: [:]).first?.contains("task bump") == true)

        try (toolsTable + linear).write(to: fx.project.configURL, atomically: true, encoding: .utf8)
        #expect(try library.load(fx.name).definition.mcpTools == ["mcp__linear__get_issue"])
        #expect(library.summary(fx.name).mcpTools == ["mcp__linear__get_issue"])
        let config = try Config.load(from: fx.project.configURL)
        #expect(library.mcpProblems(servers: config.mcpServers).isEmpty)
    }

    @Test func noConfigAtAllRefusesATaskThatNamesTools() throws {
        let fx = try TaskFixture(front: "fix: pr\nmcp_tools: mcp__linear__get_issue")
        #expect(throws: TaskFileError.self) { try TaskLibrary(project: fx.project).load(fx.name) }
    }
}

struct McpServerConfigTests {
    @Test func httpAndStdioTablesParseAndTheTaskFileCannotDefineOne() throws {
        let config = try Config.parse(
            toolsTable + linear
                + "[mcp_servers.local]\ncommand = \"node\"\nargs = [\"server.js\", \"--x\"]\n")
        #expect(
            config.mcpServers["linear"]
                == McpServer(name: "linear", transport: .http, url: "https://mcp.linear.app/mcp"))
        #expect(
            config.mcpServers["local"]
                == McpServer(name: "local", transport: .stdio, command: "node", args: ["server.js", "--x"]))
        #expect(try Config.parse(toolsTable).mcpServers.isEmpty)
    }

    @Test func badTablesAreRefusedWithAMessageEach() {
        #expect(
            configProblems(toolsTable + "[mcp_servers.a]\ntype = \"ws\"\nurl = \"https://x.io\"\n").count
                == 1)
        #expect(configProblems(toolsTable + "[mcp_servers.a]\ntype = \"http\"\n").count == 1)
        #expect(
            configProblems(toolsTable + "[mcp_servers.a]\ntype = \"http\"\nurl = \"http://x.io/mcp\"\n")
                .count == 1)
        #expect(configProblems(toolsTable + "[mcp_servers.a]\ntype = \"stdio\"\n").count == 1)
        #expect(
            configProblems(toolsTable + "[mcp_servers.a]\ncommand = \"x\"\nurl = \"https://x.io\"\n")
                .count == 1)
        #expect(
            configProblems(toolsTable + "[mcp_servers.a]\ncommand = \"x\"\nenv = \"K=v\"\n").first?
                .contains("unknown key 'env'") == true)
        #expect(configProblems(toolsTable + "[mcp_servers.a__b]\ncommand = \"x\"\n").count == 1)
        #expect(
            configProblems(toolsTable + "[mcp_servers]\nx = 1\n").first?.contains("unknown table") == true
        )
    }
}

struct McpInvocationTests {
    private func config(_ extra: String = "") throws -> Config {
        try Config.parse(extra + toolsTable + linear)
    }

    private func access(_ tools: [String]) throws -> McpAccess {
        try McpAccess.write(
            tools: tools, servers: try config().mcpServers, in: try Scratch.directory("mcp"))
    }

    @Test func aTaskTurnGetsTheConfigFileStrictModeAndExactlyItsTools() throws {
        let mcp = try access(["mcp__linear__get_issue", "mcp__linear__save_issue"])
        let args = try config().invocation(
            for: TurnRequest(sessionID: session, resume: false, budgetUSD: 1, prompt: "x", mcp: mcp)
        ).arguments
        // The CLI turns MCP off under --safe-mode, so it is left out; skills and commands stay off.
        #expect(
            !args.contains("--safe-mode") && args.contains("--disable-slash-commands")
                && args.contains("--restricted"))
        let at = try #require(args.firstIndex(of: "--mcp-config"))
        #expect(args[at + 1] == mcp.configFile.path && args[at + 2] == "--strict-mcp-config")
        let allowed = try #require(args.firstIndex(of: "--allowedTools"))
        let tail = args[(allowed + 1)...].prefix { !$0.hasPrefix("--") }
        #expect(Array(tail) == ["Read", "mcp__linear__get_issue", "mcp__linear__save_issue"])
        #expect(!args.joined(separator: " ").contains("mcp__linear__*"))
        #expect(args.suffix(2) == ["--", "x"])
    }

    @Test func skillsAndCommandsStayOffForATaskTurnEvenWhenSafeModeIsOff() throws {
        let cfg = try Config.parse("safe_mode = false\n" + toolsTable + linear)
        let mcp = try McpAccess.write(
            tools: ["mcp__linear__get_issue"], servers: cfg.mcpServers, in: try Scratch.directory("mcp"))
        let args = try cfg.invocation(for: TurnRequest(sessionID: session, resume: false, budgetUSD: 1, prompt: "x", mcp: mcp))
            .arguments
        #expect(
            args.contains("--disable-slash-commands") && args.contains("--strict-mcp-config") && !args.contains("--safe-mode"))
    }

    @Test func aTurnWithoutToolsGetsNoMcpFlagAndKeepsSafeMode() throws {
        let args = try config().invocation(
            for: TurnRequest(sessionID: session, resume: false, budgetUSD: 1, prompt: "x")
        ).arguments
        #expect(args.contains("--safe-mode") && args.contains("--disable-slash-commands"))
        #expect(!args.contains("--mcp-config") && !args.contains("--strict-mcp-config"))
        #expect(!args.contains { $0.hasPrefix("mcp__") })
        // The server table alone loads nothing for a goal run.
        #expect(
            try Config.parse(toolsTable + linear).previewInvocation().arguments.contains("--safe-mode"))
    }

    @Test func aDeniedToolIsNeverAllowedAndTheDenyListStaysLast() throws {
        let cfg = try Config.parse(
            toolsTable.replacingOccurrences(
                of: "\"Bash(git push:*)\"", with: "\"mcp__linear__save_issue\"") + linear)
        let mcp = try McpAccess.write(
            tools: ["mcp__linear__get_issue", "mcp__linear__save_issue"], servers: cfg.mcpServers,
            in: try Scratch.directory("mcp"))
        let args = try cfg.invocation(
            for: TurnRequest(sessionID: session, resume: false, budgetUSD: 1, prompt: "x", mcp: mcp)
        ).arguments
        let allowed = try #require(args.firstIndex(of: "--allowedTools"))
        let tail = args[(allowed + 1)...].prefix { !$0.hasPrefix("--") }
        #expect(tail.contains("mcp__linear__get_issue") && !tail.contains("mcp__linear__save_issue"))
        let denied = try #require(args.firstIndex(of: "--disallowedTools"))
        #expect(args[denied + 1] == "mcp__linear__save_issue")
    }

    @Test func theFileHoldsOnlyTheServersTheToolsNeedPrivateAndIsRemovedAfter() throws {
        let cfg = try Config.parse(toolsTable + linear + "[mcp_servers.other]\ncommand = \"node\"\n")
        let mcp = try McpAccess.write(
            tools: ["mcp__linear__get_issue"], servers: cfg.mcpServers, in: try Scratch.directory("mcp"))
        let object =
            try JSONSerialization.jsonObject(with: Data(contentsOf: mcp.configFile)) as? [String: Any]
        let servers = try #require(object?["mcpServers"] as? [String: [String: String]])
        #expect(servers == ["linear": ["type": "http", "url": "https://mcp.linear.app/mcp"]])
        let mode =
            try FileManager.default.attributesOfItem(atPath: mcp.configFile.path)[.posixPermissions]
            as? Int
        #expect(mode == 0o600)
        mcp.remove()
        #expect(!FileManager.default.fileExists(atPath: mcp.configFile.path))
        #expect(throws: McpError.self) {
            try McpAccess.write(
                tools: ["mcp__nope__x"], servers: cfg.mcpServers, in: try Scratch.directory("mcp"))
        }
    }
}

@Suite(.processGate) struct McpThreadTests {
    private func runner(_ project: Project) throws -> ThreadRunner {
        ThreadRunner(project: project, threadID: "t1", git: try isolatedGit())
    }

    private func project(tools: [String]?) throws -> Project {
        let project = Project(root: try Scratch.directory("mcp-thread"))
        try FileManager.default.createDirectory(
            at: project.threadDirectory("t1"), withIntermediateDirectories: true)
        if let tools { try McpToolsFile.write(tools, project: project, thread: "t1") }
        return project
    }

    private let cfg = try! Config.parse(toolsTable + linear)
    private let claude = ResolvedAgent(provider: .claude, model: nil, allowUnpriced: false)

    @Test func aThreadWithoutTheFileHasNoMcpAccess() async throws {
        let none = try await runner(project(tools: nil)).mcpAccess(config: cfg, agent: claude)
        #expect(none == nil)
    }

    @Test func aTaskThreadGetsAFreshFileEachTimeForExactlyItsTools() async throws {
        let r = try runner(project(tools: ["mcp__linear__get_issue"]))
        let first = try #require(try await r.mcpAccess(config: cfg, agent: claude))
        defer { first.remove() }
        #expect(
            first.tools == ["mcp__linear__get_issue"]
                && FileManager.default.fileExists(atPath: first.configFile.path))
    }

    @Test func codexAMissingTableAndADamagedFileAreRefusedBeforeAnyTurn() async throws {
        let r = try runner(project(tools: ["mcp__linear__get_issue"]))
        let codex = ResolvedAgent(provider: .codex, model: nil, allowUnpriced: false)
        await #expect(throws: McpError.unsupportedProvider) {
            try await r.mcpAccess(config: cfg, agent: codex)
        }
        let bare = try Config.parse(toolsTable)
        await #expect(throws: McpError.self) { try await r.mcpAccess(config: bare, agent: claude) }

        let damaged = try project(tools: nil)
        try Data("{\"tools\":[\"Bash\"]}".utf8).write(to: damaged.mcpToolsURL("t1"))
        let broken = try runner(damaged)
        await #expect(throws: McpError.self) { try await broken.mcpAccess(config: cfg, agent: claude) }
    }

    @Test func aPipeOrAHugeFileInPlaceOfTheToolsFileIsRefusedWithoutBeingRead() throws {
        let pipe = try project(tools: nil)
        #expect(mkfifo(pipe.mcpToolsURL("t1").path, 0o600) == 0)
        // A pipe nobody writes to would block a read for ever: this returns, and refuses.
        #expect(throws: McpError.self) { try McpToolsFile.read(project: pipe, thread: "t1") }

        let huge = try project(tools: nil)
        let padding = String(repeating: " ", count: McpToolsFile.maxFileBytes + 1)
        try Data("{\"tools\":[\"mcp__linear__get_issue\"]}\(padding)".utf8).write(to: huge.mcpToolsURL("t1"))
        #expect(throws: McpError.self) { try McpToolsFile.read(project: huge, thread: "t1") }
    }
}

@Suite(.processGate) struct McpTurnTests {
    private func mcpPath(_ fx: RunnerFixture, _ id: String, _ directives: String...) async throws -> (
        path: String, argv: [String]
    ) {
        let dump = FakeClaude.scratch("mcp-dump.json")
        defer { try? FileManager.default.removeItem(atPath: dump) }
        try McpToolsFile.write(["mcp__linear__get_issue"], project: fx.project, thread: id)
        _ = try await fx.runner(id).run(
            fx.options((["dump=\(dump)"] + directives).joined(separator: ",")))
        let info = try #require(
            JSONSerialization.jsonObject(with: try Data(contentsOf: URL(fileURLWithPath: dump)))
                as? [String: Any])
        let argv = try #require(info["argv"] as? [String])
        let at = try #require(argv.firstIndex(of: "--mcp-config"))
        return (argv[at + 1], argv)
    }

    private static let server =
        "[mcp_servers.linear]\ntype = \"http\"\nurl = \"https://mcp.linear.app/mcp\"\n"

    @Test func aTaskThreadsTurnLoadsItsServersAndTheFileIsGoneWhenTheTurnEnds() async throws {
        let fx = try await RunnerFixture(extraConfig: "")
        try (try String(contentsOf: fx.project.configURL, encoding: .utf8) + "\n" + Self.server)
            .write(to: fx.project.configURL, atomically: true, encoding: .utf8)
        let id = try await fx.approvedThread()
        let (path, argv) = try await mcpPath(fx, id)
        #expect(
            path.hasPrefix(FileManager.default.temporaryDirectory.path) && path.contains("workbench-mcp-")
        )
        #expect(
            argv.contains("--strict-mcp-config") && argv.contains("mcp__linear__get_issue")
                && !argv.contains("--safe-mode"))
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func theFileIsGoneAfterATurnThatCrashed() async throws {
        let fx = try await RunnerFixture()
        try (try String(contentsOf: fx.project.configURL, encoding: .utf8) + "\n" + Self.server)
            .write(to: fx.project.configURL, atomically: true, encoding: .utf8)
        let id = try await fx.approvedThread()
        let (path, _) = try await mcpPath(fx, id, "crash-after=1")
        #expect(!FileManager.default.fileExists(atPath: path))
    }
}
