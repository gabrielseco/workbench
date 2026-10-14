import Foundation

/// The fixed tool set for a project: what `claude` may use, with nothing else negotiable per run.
public struct ToolSet: Sendable, Equatable {
    /// Built-in tools made available at all (`--tools`). Bare names only.
    public var available: [String]
    /// Patterns allowed without a prompt (`--allowedTools`). Bare names or `Name(pattern)`.
    public var allowed: [String]
    /// Patterns always denied (`--disallowedTools`).
    public var denied: [String]
}

/// `.workbench/config.toml`.
public struct Config: Sendable, Equatable {
    public static let defaultClaudePath = "claude"
    public static let defaultBudgetUSD: Decimal = 5

    /// `claude` by name (looked up on PATH) or by path.
    public var claudePath: String
    /// Run `claude` with `--safe-mode --disable-slash-commands`: no CLAUDE.md, skills, plugins, hooks, MCP
    /// servers, custom agents or user settings. Auth, the model and the fixed tool set are unaffected.
    /// On by default: it makes a run depend on the goal and the tool set and nothing installed on the
    /// machine, and in the task 9 measurement it cut a two-call run from about 180k to 2k tokens of
    /// context. Turn it off to let a project's CLAUDE.md and your plugins in.
    public var safeMode: Bool
    /// Put the repository's `AGENTS.md` (else `CLAUDE.md`) in the first prompt of a thread. Safe mode keeps
    /// `claude` itself from reading it, so Workbench does.
    public var projectInstructions: Bool
    /// `--model` for every turn. Unset means the CLI's own default; note `--restricted` ignores the user's
    /// settings files, so that default is not the one chosen in an interactive session.
    public var model: String?
    /// The project's own check (tests, lint). Added to the allowed tools as `Bash(<command>:*)`.
    public var checkCommand: String?
    /// Run once in a new worktree before its first turn (an install step). Run by Workbench, never offered to
    /// `claude`, so it is not added to the allowed tools.
    public var setupCommand: String?
    /// Used when drafting a new goal. Goals carry their own `budget_usd`.
    public var defaultBudgetUSD: Decimal
    /// Extra environment variables passed to `claude`, on top of the fixed minimal set.
    public var envPass: [String]
    public var tools: ToolSet

    /// `allowed` plus the check command, which Claude must be able to run.
    public var effectiveAllowedTools: [String] {
        var allowed = tools.allowed
        if let check = checkCommand {
            let pattern = "Bash(\(check):*)"
            if !allowed.contains(pattern) { allowed.append(pattern) }
        }
        return allowed
    }

    public static func load(from url: URL) throws -> Config {
        let text: String
        do { text = try String(contentsOf: url, encoding: .utf8) } catch {
            let code: ConfigProblem.Code =
                FileManager.default.fileExists(atPath: url.path) ? .unreadable : .notFound
            let message =
                code == .notFound
                ? "no config at \(url.path); create it (see docs/spec/goal-file.md, 'Tool permissions')"
                : "cannot read \(url.path): \(error.localizedDescription)"
            throw ConfigError(problems: [ConfigProblem(code: code, line: nil, message: message)])
        }
        return try parse(text)
    }

    public static func parse(_ text: String) throws -> Config {
        let (document, syntaxProblems) = TOMLSubset.parse(text)
        var problems = syntaxProblems
        func fail(_ code: ConfigProblem.Code, _ line: Int?, _ message: String) {
            problems.append(ConfigProblem(code: code, line: line, message: message))
        }

        let rootKeys: Set<String> = [
            "claude_path", "check_command", "setup_command", "default_budget_usd", "env_pass", "model", "safe_mode",
            "project_instructions",
        ]
        let toolKeys: Set<String> = ["available", "allowed", "denied"]

        for (name, table) in document.tables.sorted(by: { $0.key < $1.key }) {
            if name != "" && name != "tools" {
                fail(.unknownTable, table.line, "unknown table [\(name)]")
                continue
            }
            let known = name == "" ? rootKeys : toolKeys
            for (key, entry) in table.entries.sorted(by: { $0.key < $1.key }) where !known.contains(key) {
                let location = name == "" ? "" : " in [\(name)]"
                fail(.unknownKey, entry.line, "unknown key '\(key)'\(location)")
            }
        }

        func string(_ table: String, _ key: String) -> (value: String, line: Int)? {
            guard let entry = document.tables[table]?.entries[key] else { return nil }
            guard case .string(let s) = entry.value else {
                fail(.wrongType, entry.line, "'\(key)' must be a string, found \(entry.value.typeName)")
                return nil
            }
            return (s, entry.line)
        }

        func strings(_ table: String, _ key: String) -> (values: [String], line: Int)? {
            guard let entry = document.tables[table]?.entries[key] else { return nil }
            guard case .array(let items) = entry.value else {
                fail(.wrongType, entry.line, "'\(key)' must be an array of strings, found \(entry.value.typeName)")
                return nil
            }
            var out: [String] = []
            for item in items {
                guard case .string(let s) = item else {
                    fail(.wrongType, entry.line, "'\(key)' must contain only strings, found \(item.typeName)")
                    return nil
                }
                out.append(s)
            }
            return (out, entry.line)
        }

        // Root
        var claudePath = defaultClaudePath
        if let (value, line) = string("", "claude_path") {
            if value.isEmpty || value.contains("\n") || value.contains("\0") {
                fail(.invalidValue, line, "'claude_path' must be a command name or a path")
            } else {
                claudePath = value
            }
        }

        var safeMode = true
        if let entry = document.tables[""]?.entries["safe_mode"] {
            if case .bool(let value) = entry.value {
                safeMode = value
            } else {
                fail(.wrongType, entry.line, "'safe_mode' must be true or false, found \(entry.value.typeName)")
            }
        }

        var projectInstructions = true
        if let entry = document.tables[""]?.entries["project_instructions"] {
            if case .bool(let value) = entry.value {
                projectInstructions = value
            } else {
                fail(
                    .wrongType, entry.line,
                    "'project_instructions' must be true or false, found \(entry.value.typeName)")
            }
        }

        var model: String?
        if let (value, line) = string("", "model") {
            if value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:\[\]-]*$"#, options: .regularExpression) == nil {
                fail(.invalidValue, line, "'model' must be a model name or alias like \"haiku\"")
            } else {
                model = value
            }
        }

        func command(_ key: String) -> String? {
            guard let (value, line) = string("", key) else { return nil }
            if let reason = Config.checkCommandProblem(value) {
                fail(.invalidValue, line, "'\(key)' \(reason)")
                return nil
            }
            return value
        }
        let checkCommand = command("check_command")
        let setupCommand = command("setup_command")

        var budget = defaultBudgetUSD
        if let entry = document.tables[""]?.entries["default_budget_usd"] {
            switch entry.value {
            case .int(let n) where n > 0: budget = Decimal(n)
            case .number(let d) where d > 0: budget = d
            default:
                fail(.invalidValue, entry.line, "'default_budget_usd' must be a positive number")
            }
        }

        var envPass: [String] = []
        if let (values, line) = strings("", "env_pass") {
            for name in values where name.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) == nil {
                fail(.invalidValue, line, "'env_pass' entry '\(name)' is not an environment variable name")
            }
            envPass = values
        }

        // [tools]
        guard let toolsTable = document.tables["tools"] else {
            fail(.missingKey, nil, "missing [tools] table with 'available'")
            throw ConfigError(problems: sorted(problems))
        }
        var available: [String] = []
        if let (values, line) = strings("tools", "available") {
            if values.isEmpty { fail(.invalidValue, line, "'available' must list at least one tool") }
            for name in values where !isBareToolName(name) {
                fail(.invalidValue, line, "'available' entry '\(name)' must be a bare tool name like \"Read\"")
            }
            available = values
        } else if toolsTable.entries["available"] == nil {
            fail(.missingKey, toolsTable.line, "missing required key 'available' in [tools]")
        }

        var allowed: [String] = []
        var denied: [String] = []
        for (key, assign) in [("allowed", 0), ("denied", 1)] {
            guard let (values, line) = strings("tools", key) else { continue }
            for pattern in values where !isToolPattern(pattern) {
                fail(.invalidValue, line, "'\(key)' entry '\(pattern)' is not a tool name or 'Name(pattern)'")
            }
            if assign == 0 { allowed = values } else { denied = values }
        }
        for pattern in allowed where denied.contains(pattern) {
            fail(.conflict, toolsTable.line, "'\(pattern)' is both allowed and denied")
        }

        guard problems.isEmpty else { throw ConfigError(problems: sorted(problems)) }
        return Config(
            claudePath: claudePath, safeMode: safeMode, projectInstructions: projectInstructions,
            model: model, checkCommand: checkCommand, setupCommand: setupCommand,
            defaultBudgetUSD: budget,
            envPass: envPass, tools: ToolSet(available: available, allowed: allowed, denied: denied))
    }

    private static func sorted(_ problems: [ConfigProblem]) -> [ConfigProblem] {
        problems.enumerated().sorted {
            ($0.element.line ?? .max, $0.offset) < ($1.element.line ?? .max, $1.offset)
        }.map(\.element)
    }

    static func isBareToolName(_ s: String) -> Bool {
        s.range(of: #"^[A-Za-z_][A-Za-z0-9_.-]*$"#, options: .regularExpression) != nil
    }

    static func isToolPattern(_ s: String) -> Bool {
        s.range(of: #"^[A-Za-z_][A-Za-z0-9_.-]*(\([^\n\r]+\))?$"#, options: .regularExpression) != nil
    }

    /// The check command ends up inside `Bash(<command>:*)`, so it must be one plain command: no pipes,
    /// chains, substitutions or redirects that the pattern could not meaningfully allow.
    static func checkCommandProblem(_ s: String) -> String? {
        if s.trimmingCharacters(in: .whitespaces).isEmpty { return "must not be empty" }
        if s.hasPrefix("-") { return "must not start with '-'" }
        if s.contains(where: { "&|;<>$`()\\\"'\n\r\0".contains($0) }) {
            return "must be a single plain command (no shell operators, quotes or substitutions)"
        }
        return nil
    }

    /// A starting point for `workbench init`.
    public static let exampleTOML = """
        # Workbench project config. One fixed tool set per project.

        # claude_path = "claude"           # name on PATH, or an absolute path
        # safe_mode = true                 # no CLAUDE.md, skills, plugins, hooks or MCP in runs (default)
        # project_instructions = true     # put AGENTS.md (else CLAUDE.md) in the first prompt (default)
        # model = "haiku"                  # --model for every turn; unset = the CLI default
        # check_command = "scripts/check.sh"
        # setup_command = "mix deps.get"   # run once in a new worktree before its first turn
        # default_budget_usd = 5.00        # used when drafting a goal
        # env_pass = ["ANTHROPIC_API_KEY"] # extra variables claude, setup and check may see (all run on an allowlist)
        # A version manager sets its own: for mise on Elixir, env_pass = ["MIX_HOME", "MIX_ARCHIVES"]

        [tools]
        # Built-in tools that exist at all. File tools are confined to the worktree (--restricted).
        available = ["Read", "Grep", "Glob", "Edit", "Write", "Bash"]
        # Allowed without asking. Anything not listed is denied automatically. A narrow test command lets a
        # run check what it changed without repeating the full check: for a Swift project add
        # "Bash(swift build:*)" and "Bash(swift test --filter:*)".
        allowed = [
          "Read", "Grep", "Glob", "Edit", "Write",
          "Bash(git status:*)", "Bash(git diff:*)", "Bash(git add:*)", "Bash(git commit:*)",
        ]
        denied = ["Bash(git push:*)", "Bash(gh pr merge:*)", "Bash(rm -rf:*)"]
        """
}
