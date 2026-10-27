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
public enum AppType: String, Sendable, Equatable, CaseIterable {
    case web
    case desktop
}

/// `[pr_review]`: the Codex review of a shipped pull request (docs/plan/P5-review-loop.md).
public struct PRReviewConfig: Sendable, Equatable {
    public static let defaultMaxRounds = 3
    public static let maxRoundsCeiling = 10

    /// A repo-relative file of this project's review invariants, read from the pull request's head and added
    /// to the prompt.
    public var checklist: String?
    /// Reviews of one pull request; Workbench counts them from its own log.
    public var maxRounds: Int = PRReviewConfig.defaultMaxRounds

    public init(checklist: String? = nil, maxRounds: Int = PRReviewConfig.defaultMaxRounds) {
        self.checklist = checklist
        self.maxRounds = maxRounds
    }

    /// Why a checklist path cannot be used, nil when it can: it ends up in a path under a checkout.
    static func checklistProblem(_ path: String) -> String? {
        if path.isEmpty || path.contains("\0") || path.contains("\n") || path.contains("\r") {
            return "must be a file path"
        }
        if path.hasPrefix("/") || path.hasPrefix("~") || path.hasPrefix("-") { return "must be a path inside the repository" }
        if path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." || $0.isEmpty }) {
            return "must be a path inside the repository (no '..' or empty parts)"
        }
        return nil
    }
}

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
    /// The project's own check (tests, lint). Added to the allowed tools as `Bash(<command>:*)`.
    public var checkCommand: String?
    /// Run once in a new worktree before its first turn (an install step). Run by Workbench, never offered to
    /// `claude`, so it is not added to the allowed tools.
    public var setupCommand: String?
    /// Repo-relative files or globs copied from the main checkout into each new worktree, before `setup_command`:
    /// the git-ignored files a checkout does not carry (`.env`). Files git does not ignore are not copied.
    public var copy: [String] = []
    /// What the project's verifier drives. `desktop` needs Screen Recording, which `doctor` checks.
    public var appType: AppType = .web
    /// The dollar cap for a judge, a review and a review loop, and for a new goal's `budget_usd` when `default_budget_usd` is set.
    public var defaultBudgetUSD: Decimal
    /// True when the config sets `default_budget_usd`: only then does a new goal get a `budget_usd`, else `spend_policy: timeout_only`.
    public var defaultBudgetConfigured = false
    /// Extra environment variables passed to `claude`, on top of the fixed minimal set.
    public var envPass: [String]
    public var tools: ToolSet
    public var review: ReviewConfig = ReviewConfig()
    /// `[verifier]`, or nil when the project declares none.
    public var verifier: VerifierConfig?

    /// `[run]`, or nil when the project declares no way to start its app.
    public var run: RunConfig?

    /// `[providers.<id>]` and `[agents.<role>]`: which provider and model each responsibility asks for. Read through
    /// `resolvedRunAgent`, `resolvedJudgeAgent`, `resolvedReviewAgent`, `resolvedGoalAgent`, `resolvedShipAgent`
    /// and `resolvedPlanAgent`.
    public var agents = AgentsConfig()

    /// The editor `workbench open` starts on a thread's worktree. Only `open` reads it; a run never does.
    public var editor: String?

    /// `--model` for the verifier: its own, else nil for the CLI's default.
    public var verifierModel: String? { verifier?.model }

    /// The `pr-review` stage's checklist and round cap, from `[review.stage.pr-review]` or the older `[pr_review]`.
    public var prReview: PRReviewConfig {
        PRReviewConfig(checklist: review.prReview.checklist, maxRounds: review.prReview.maxRounds)
    }

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

    // swiftlint:disable:next function_body_length
    public static func parse(_ text: String) throws -> Config {
        let (document, syntaxProblems) = TOMLSubset.parse(text)
        var problems = syntaxProblems
        func fail(_ code: ConfigProblem.Code, _ line: Int?, _ message: String) {
            problems.append(ConfigProblem(code: code, line: line, message: message))
        }

        let rootKeys: Set<String> = [
            "claude_path", "check_command", "setup_command", "app_type",
            "default_budget_usd", "env_pass", "safe_mode", "project_instructions", "copy", "editor",
        ]
        let toolKeys: Set<String> = ["available", "allowed", "denied"]

        // The review and verifier tables check their own keys (ReviewConfig.parse, VerifierConfig.parse).
        let leftToTheirOwn = { (name: String) in
            ReviewConfig.owns(table: name) || VerifierConfig.owns(table: name) || RunConfig.owns(table: name)
                || AgentsConfig.owns(table: name)
        }
        for (name, table) in document.tables.sorted(by: { $0.key < $1.key }) where !leftToTheirOwn(name) {
            if name != "" && name != "tools" {
                fail(.unknownTable, table.line, "unknown table [\(name)]")
                continue
            }
            let known = name == "" ? rootKeys : toolKeys
            for (key, entry) in table.entries.sorted(by: { $0.key < $1.key }) where !known.contains(key) {
                if name == "", let removed = Self.removedKeyMessage(key) {
                    fail(.unknownKey, entry.line, removed)
                    continue
                }
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

        let editor = string("", "editor").flatMap { editorValue($0.value, line: $0.line, fail: fail) }

        var appType = AppType.web
        if let (value, line) = string("", "app_type") {
            if let parsed = AppType(rawValue: value) {
                appType = parsed
            } else {
                let allowed = AppType.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: " or ")
                fail(.invalidValue, line, "'app_type' must be \(allowed)")
            }
        }

        var budget = defaultBudgetUSD
        if let entry = document.tables[""]?.entries["default_budget_usd"] {
            switch entry.value {
            case .int(let n) where n > 0: budget = Decimal(n)
            case .number(let d) where d > 0: budget = d
            default:
                fail(.invalidValue, entry.line, "'default_budget_usd' must be a positive number")
            }
        }

        let review = ReviewConfig.parse(document, fail: fail)
        let verifier = VerifierConfig.parse(document, fail: fail)
        let run = RunConfig.parse(document, fail: fail)
        let agents = AgentsConfig.parse(document, fail: fail)
        claudePath = agents.claudeExecutable(claudePathLine: document.tables[""]?.entries["claude_path"]?.line, fail: fail)
            ?? claudePath

        var envPass: [String] = []
        if let (values, line) = strings("", "env_pass") {
            for name in values where name.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) == nil {
                fail(.invalidValue, line, "'env_pass' entry '\(name)' is not an environment variable name")
            }
            envPass = values
        }

        var copy: [String] = []
        if let (values, line) = strings("", "copy") {
            for pattern in values {
                if let reason = WorktreeCopier.patternProblem(pattern) {
                    fail(.invalidValue, line, "'copy' entry '\(pattern)' \(reason)")
                }
            }
            copy = values
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
        var config = Config(
            claudePath: claudePath, safeMode: safeMode, projectInstructions: projectInstructions,
            checkCommand: checkCommand, setupCommand: setupCommand, copy: copy,
            appType: appType, defaultBudgetUSD: budget,
            envPass: envPass, tools: ToolSet(available: available, allowed: allowed, denied: denied),
            review: review, verifier: verifier, run: run)
        config.editor = editor
        config.agents = agents
        config.defaultBudgetConfigured = document.tables[""]?.entries["default_budget_usd"] != nil
        return config
    }

    /// The `editor` key, in the project's config or the global one: the value, or nil after `fail` has been told.
    static func editorValue(_ value: String, line: Int, fail: ReviewConfig.Fail) -> String? {
        guard let reason = Editor.valueProblem(value) else { return value }
        fail(.invalidValue, line, "'editor' \(reason)")
        return nil
    }

    /// Keys an older config used for the verify step, which `[verifier]` replaced.
    private static let removedVerifyKeys: Set<String> = ["verify_command", "verify_timeout_min"]

    /// Root model keys the `[agents.<role>]` tables replaced, with where each now lives.
    static let removedModelKeys: [String: String] = [
        "model": "'model' in [agents.run]",
        "judge_model": "'model' in [agents.judge]",
        "describe_model": "'model' in [agents.ship]",
        "plan_model": "'model' in [agents.plan]",
    ]

    /// What to say about a root key an older config used, nil for a key that never existed.
    static func removedKeyMessage(_ key: String) -> String? {
        if removedVerifyKeys.contains(key) { return "'\(key)' was removed: replace it with a [verifier] table" }
        return removedModelKeys[key].map { "'\(key)' was removed: it is now \($0)" }
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

    /// `exampleTOML` with the global defaults filled in as real lines, for `workbench new`.
    public static func exampleTOML(claudePath: String?, model: String?) -> String {
        func quoted(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        // The `[agents.run]` example becomes a real table holding the model; every other `# model = ` stays a comment.
        var claudePathDone = false
        var inRunTable = false
        var modelDone = false
        let lines = exampleTOML.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            if let claudePath, !claudePathDone, line.hasPrefix("# claude_path = ") {
                claudePathDone = true
                return "claude_path = \(quoted(claudePath))"
            }
            if model != nil, !modelDone, line.hasPrefix("# [agents.run]") {
                inRunTable = true
                return String(line.dropFirst(2))
            }
            if let model, inRunTable, !modelDone, line.hasPrefix("# model = ") {
                modelDone = true
                return "model = \(quoted(model))"
            }
            return String(line)
        }
        return lines.joined(separator: "\n")
    }

    /// A starting point for `workbench init`.
    public static let exampleTOML = """
        # Workbench project config. One fixed tool set per project.

        # claude_path = "claude"           # name on PATH, or an absolute path
        # safe_mode = true                 # no CLAUDE.md, skills, plugins, hooks or MCP in runs (default)
        # project_instructions = true     # put AGENTS.md (else CLAUDE.md) in the first prompt (default)
        # check_command = "scripts/check.sh"
        # setup_command = "mix deps.get"   # run once in a new worktree before its first turn
        # copy = [".env.*", "example/.env"] # git-ignored files copied from this checkout into each new worktree
        # app_type = "web"                 # "desktop" if the verifier captures the screen: doctor checks Screen Recording
        # default_budget_usd = 5.00        # opt in: new goals get this budget_usd (API billing); else timeout_only
        # env_pass = ["ANTHROPIC_API_KEY"] # extra variables claude, setup and check may see (all run on an allowlist)
        # A version manager sets its own: for mise on Elixir, env_pass = ["MIX_HOME", "MIX_ARCHIVES"]
        # editor = "cursor"                # `workbench open`: cursor, code, zed, subl, windsurf or one plain command

        # [pr_review]                      # `workbench pr-review`: Codex reviews the shipped pull request
        # checklist = "docs/REVIEW.md"     # optional: this project's review invariants, read from the PR head
        # max_rounds = 3                   # reviews of one pull request, counted from the event log (1 to 10)
        # (also accepted as [review.stage.pr-review]; `[review] stages = [...]` lists the review stages, in order)

        # [providers.codex]                # which executable runs a provider (claude: same as claude_path)
        # executable = "/opt/homebrew/bin/codex"

        # [agents.run]                     # provider, model and reasoning_effort per responsibility: every model is set here
        # model = "opus"                   # the coding turns; a goal's own `model` wins; unset = the provider's default
        # reasoning_effort = "high"        # low, medium, high, xhigh or max; unset = the provider's own
        # [agents.judge]                   # unset keeps the defaults: run, judge, ship and plan on claude,
        # provider = "claude"              # review on codex, goal drafting off
        # model = "sonnet"                 # `workbench judge --model` wins
        # [agents.ship]                    # the PR description and its refresh, from the prompt (codex can still read files)
        # model = "haiku"
        # [agents.plan]                    # `workbench plan`: reads a checkout of the base; `plan --model` wins
        # model = "opus"                   # ship and plan also take provider = "codex" and allow_unpriced, as judge does
        # [agents.review]                  # also review.stage.<name>: provider, model, allow_unpriced
        # allow_unpriced = true            # the default: codex (no dollar cap) runs on its timeout; false refuses it
        #                                  # (never for [agents.run], whose spending the goal approves)

        # [run]                            # how the verifier's app is started: Workbench runs it and stops it
        # command = "npm run dev:mock"     # one plain command, run in the worktree with WORKBENCH_PORT (and PORT) set
        # ready_url = "http://localhost:{port}/"  # or ready_line = "Triage on mock data" (a regex on its output)

        # [verifier]                       # on by default: runs the project's skill after a passing check
        # enabled = false                  # turn it off; with no skill file at the base it is skipped anyway
        # skill = ".claude/skills/verify/SKILL.md"  # read from the base commit

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
