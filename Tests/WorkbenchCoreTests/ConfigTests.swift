import Foundation
import Testing

@testable import WorkbenchCore

private let validConfig = """
    check_command = "scripts/check.sh"
    default_budget_usd = 2.50

    [tools]
    available = ["Read", "Edit", "Bash"]
    allowed = [
      "Read", "Edit",            # file tools, confined by --restricted
      "Bash(git status:*)",
    ]
    denied = ["Bash(git push:*)"]
    """

private func problems(in text: String) -> [ConfigProblem] {
    do {
        _ = try Config.parse(text)
        return []
    } catch let error as ConfigError {
        return error.problems
    } catch {
        Issue.record("unexpected error \(error)")
        return []
    }
}

private func codes(_ text: String) -> [ConfigProblem.Code] { problems(in: text).map(\.code) }

@Suite struct TOMLSubsetTests {
    @Test func readsScalarsArraysAndTables() {
        let (doc, problems) = TOMLSubset.parse(
            """
            name = "a # not a comment"   # a comment
            lit = 'C:\\path'
            n = 3
            f = 1.50
            on = true
            [t]
            list = ["x", 'y',]
            multi = [
              "a",
              "b",  # trailing
            ]
            """)
        #expect(problems.isEmpty)
        let root = doc.tables[""]!.entries
        #expect(root["name"]?.value == .string("a # not a comment"))
        #expect(root["lit"]?.value == .string("C:\\path"))
        #expect(root["n"]?.value == .int(3))
        #expect(root["f"]?.value == .number(Decimal(string: "1.50")!))
        #expect(root["on"]?.value == .bool(true))
        let t = doc.tables["t"]!.entries
        #expect(t["list"]?.value == .array([.string("x"), .string("y")]))
        #expect(t["multi"]?.value == .array([.string("a"), .string("b")]))
        #expect(t["multi"]?.line == 8)
    }

    @Test func basicStringEscapes() {
        let (doc, problems) = TOMLSubset.parse(#"s = "a\"b\\c\n""#)
        #expect(problems.isEmpty)
        #expect(doc.tables[""]!.entries["s"]?.value == .string("a\"b\\c\n"))
    }

    @Test(arguments: [
        ("a.b = 1", ConfigProblem.Code.unsupportedSyntax),
        ("[a..b]", .unsupportedSyntax),
        ("[\"a\".b]", .unsupportedSyntax),
        ("[a.]", .unsupportedSyntax),
        ("[[a]]", .unsupportedSyntax),
        ("x = { a = 1 }", .unsupportedSyntax),
        ("x = \"\"\"\nmulti\n\"\"\"", .unsupportedSyntax),
        ("x = 2026-10-12", .syntax),
        ("x = bare", .syntax),
        ("x = \"open", .syntax),
        ("x = [\"a\"", .syntax),
        ("just words", .syntax),
        ("x = 1 2", .syntax),
    ])
    func rejectsWhatItDoesNotSupport(text: String, code: ConfigProblem.Code) {
        let (_, problems) = TOMLSubset.parse(text)
        #expect(problems.first?.code == code, "\(text) -> \(problems)")
    }

    @Test func aDottedHeaderIsOneTableNamedAsWritten() {
        let (doc, problems) = TOMLSubset.parse("[review.stage.pr-review]\nmax_rounds = 2\n")
        #expect(problems.isEmpty)
        #expect(doc.tables["review.stage.pr-review"]?.entries["max_rounds"]?.value == .int(2))
        #expect(doc.tables["review"] == nil)
    }

    @Test func multilineStringBodyDoesNotCascade() {
        let (doc, problems) = TOMLSubset.parse("a = \"\"\"\nnot a key\nstill not\n\"\"\"\nb = 1\n")
        #expect(problems.map(\.code) == [.unsupportedSyntax])
        #expect(doc.tables[""]!.entries["b"]?.value == .int(1))
    }

    @Test func duplicatesAreReported() {
        let (_, problems) = TOMLSubset.parse("a = 1\na = 2\n[t]\n[t]\n")
        #expect(problems.map(\.code) == [.duplicateKey, .duplicateTable])
        #expect(problems.map(\.line) == [2, 4])
    }
}

@Suite struct ConfigTests {
    @Test func parsesAValidConfig() throws {
        let config = try Config.parse(validConfig)
        #expect(config.claudePath == "claude")
        #expect(config.checkCommand == "scripts/check.sh")
        #expect(config.defaultBudgetUSD == Decimal(string: "2.5"))
        #expect(config.tools.available == ["Read", "Edit", "Bash"])
        #expect(config.tools.allowed == ["Read", "Edit", "Bash(git status:*)"])
        #expect(config.tools.denied == ["Bash(git push:*)"])
        #expect(config.effectiveAllowedTools.last == "Bash(scripts/check.sh:*)")
    }

    @Test func defaultsApplyWhenOptionalKeysAreMissing() throws {
        let config = try Config.parse("[tools]\navailable = [\"Read\"]\n")
        #expect(config.claudePath == "claude")
        #expect(config.checkCommand == nil)
        #expect(config.defaultBudgetUSD == 5)
        #expect(config.tools.allowed.isEmpty)
        #expect(config.envPass.isEmpty)
    }

    @Test func appTypeIsWebOrDesktopAndDefaultsToWeb() throws {
        let tools = "[tools]\navailable = [\"Read\"]\n"
        #expect(try Config.parse(tools).appType == .web)
        #expect(try Config.parse("app_type = \"web\"\n" + tools).appType == .web)
        #expect(try Config.parse("app_type = \"desktop\"\n" + tools).appType == .desktop)
        do {
            _ = try Config.parse("app_type = \"mobile\"\n" + tools)
            Issue.record("expected a problem")
        } catch let error as ConfigError {
            let text = "\(error)"
            #expect(text.contains("app_type") && text.contains("\"web\"") && text.contains("\"desktop\""), "\(text)")
        }
    }

    @Test func theExampleConfigParses() throws {
        let config = try Config.parse(Config.exampleTOML)
        #expect(config.tools.available.contains("Bash"))
        #expect(config.tools.denied.contains("Bash(git push:*)"))
        #expect(Config.exampleTOML.contains("MIX_HOME"), "the example says what a version manager needs")
    }

    @Test func missingFileSaysWhere() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID())/config.toml")
        do {
            _ = try Config.load(from: url)
            Issue.record("expected an error")
        } catch let error as ConfigError {
            #expect(error.problems.map(\.code) == [.notFound])
            #expect(error.problems[0].message.contains(url.path))
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func loadsFromDisk() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wb-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("config.toml")
        try validConfig.write(to: url, atomically: true, encoding: .utf8)
        #expect(try Config.load(from: url).checkCommand == "scripts/check.sh")
    }

    @Test func unknownKeysAndTablesAreErrors() {
        let found = problems(
            in: """
                chek_command = "x"
                [tools]
                available = ["Read"]
                allow = ["Read"]
                [extras]
                a = 1
                """)
        #expect(found.map(\.code) == [.unknownKey, .unknownKey, .unknownTable])
        #expect(found[0].message.contains("chek_command"))
        #expect(found[1].message.contains("allow"))
    }

    @Test func toolsTableAndAvailableAreRequired() {
        #expect(codes("check_command = \"x\"") == [.missingKey])
        #expect(codes("[tools]\nallowed = [\"Read\"]") == [.missingKey])
        #expect(codes("[tools]\navailable = []") == [.invalidValue])
    }

    @Test func wrongTypesAreNamed() {
        #expect(codes("claude_path = 3\n[tools]\navailable = [\"Read\"]") == [.wrongType])
        #expect(codes("[tools]\navailable = \"Read\"") == [.wrongType])
        #expect(codes("[tools]\navailable = [\"Read\", 3]") == [.wrongType])
        #expect(codes("env_pass = [1]\n[tools]\navailable = [\"Read\"]") == [.wrongType])
    }

    @Test(arguments: ["Bash(git status:*)", "-rf", "has space", ""])
    func availableMustBeBareToolNames(name: String) {
        let text = "[tools]\navailable = [\"\(name)\"]"
        #expect(codes(text).contains(.invalidValue))
    }

    @Test(arguments: ["-Read", "Read Edit", "(x)", ""])
    func allowedMustBeToolPatterns(pattern: String) {
        let text = "[tools]\navailable = [\"Read\"]\nallowed = [\"\(pattern)\"]"
        #expect(codes(text).contains(.invalidValue))
    }

    @Test func allowedAndDeniedMayNotOverlap() {
        let text = "[tools]\navailable = [\"Bash\"]\nallowed = [\"Bash(ls:*)\"]\ndenied = [\"Bash(ls:*)\"]"
        #expect(codes(text) == [.conflict])
    }

    @Test(arguments: ["a && b", "a | b", "a; b", "$(x)", "`x`", "a > out", "-x", "  ", "a \"b\""])
    func checkCommandMustBeOnePlainCommand(command: String) {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let text = "check_command = \"\(escaped)\"\n[tools]\navailable = [\"Read\"]"
        #expect(codes(text) == [.invalidValue])
    }

    @Test(arguments: [0, -1])
    func budgetMustBePositive(n: Int) {
        #expect(codes("default_budget_usd = \(n)\n[tools]\navailable = [\"Read\"]") == [.invalidValue])
    }

    @Test func envPassMustBeVariableNames() {
        #expect(codes("env_pass = [\"A=1\"]\n[tools]\navailable = [\"Read\"]") == [.invalidValue])
    }

    @Test func problemsComeBackInFileOrder() {
        let found = problems(
            in: """
                default_budget_usd = 0
                check_command = "a && b"
                [tools]
                available = []
                """)
        #expect(found.map(\.line) == [1, 2, 4])
    }
}

@Suite struct InvocationTests {
    private let session = UUID(uuidString: "E79CF457-1714-495A-9FFE-526C12A4852E")!

    @Test func firstTurnArgv() throws {
        let config = try Config.parse(validConfig)
        let turn = TurnRequest(
            sessionID: session, resume: false, budgetUSD: 5, prompt: "Do the thing", appendSystemPrompt: "Be brief")
        let invocation = try config.invocation(for: turn)

        #expect(invocation.executable == "claude")
        #expect(
            invocation.arguments == [
                "-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                "--permission-prompts", "none", "--restricted", "--safe-mode", "--disable-slash-commands",
                "--session-id", "e79cf457-1714-495a-9ffe-526c12a4852e",
                "--max-budget-usd", "5",
                "--tools", "Read", "Edit", "Bash",
                "--allowedTools", "Read", "Edit", "Bash(git status:*)", "Bash(scripts/check.sh:*)",
                "--disallowedTools", "Bash(git push:*)",
                "--append-system-prompt", "Be brief",
                "--", "Do the thing",
            ])
    }

    @Test func safeModeIsOnByDefaultAndCanBeTurnedOff() throws {
        func args(_ toml: String) throws -> [String] {
            try Config.parse(toml).invocation(
                for: TurnRequest(sessionID: session, resume: false, budgetUSD: 1, prompt: "x")).arguments
        }
        let on = try args("[tools]\navailable = [\"Read\"]")
        #expect(on.contains("--safe-mode"))
        #expect(on.contains("--disable-slash-commands"))
        #expect(on.contains("--restricted"))

        let off = try args("safe_mode = false\n[tools]\navailable = [\"Read\"]")
        #expect(!off.contains("--safe-mode"))
        #expect(!off.contains("--disable-slash-commands"))
        #expect(off.contains("--restricted"), "restricted is not optional")

        #expect(codes("safe_mode = \"yes\"\n[tools]\navailable = [\"Read\"]") == [.wrongType])
    }

    @Test func modelIsPassedWhenSetAndOmittedWhenNot() throws {
        let with = try Config.parse("model = \"haiku\"\n[tools]\navailable = [\"Read\"]")
        let args = try with.invocation(
            for: TurnRequest(sessionID: session, resume: false, budgetUSD: 1, prompt: "x")).arguments
        let i = try #require(args.firstIndex(of: "--model"))
        #expect(args[i + 1] == "haiku")
        #expect(i < args.firstIndex(of: "--")!)

        let without = try Config.parse("[tools]\navailable = [\"Read\"]")
        #expect(!(try without.invocation(
            for: TurnRequest(sessionID: session, resume: false, budgetUSD: 1, prompt: "x")).arguments
            .contains("--model")))
    }

    @Test(arguments: ["-x", "a b", "a;b", ""])
    func modelMustBeANameNotAFlag(model: String) {
        #expect(codes("model = \"\(model)\"\n[tools]\navailable = [\"Read\"]") == [.invalidValue])
    }

    @Test func laterTurnsResumeAndNeverReuseSessionID() throws {
        let config = try Config.parse(validConfig)
        let turn = TurnRequest(sessionID: session, resume: true, budgetUSD: 1, prompt: "More")
        let args = try config.invocation(for: turn).arguments
        #expect(args.contains("--resume"))
        #expect(!args.contains("--session-id"))
        #expect(args[args.firstIndex(of: "--resume")! + 1] == "e79cf457-1714-495a-9ffe-526c12a4852e")
    }

    @Test func restrictedIsAlwaysPassed() throws {
        let config = try Config.parse("[tools]\navailable = [\"Read\"]")
        let args = try config.invocation(for: TurnRequest(sessionID: session, resume: false, budgetUSD: 1, prompt: "x")).arguments
        #expect(args.contains("--restricted"))
        #expect(args.contains("--permission-prompts"))
    }

    @Test func promptAlwaysFollowsTheDoubleDashEvenWhenItLooksLikeAFlag() throws {
        let config = try Config.parse(validConfig)
        let args = try config.invocation(
            for: TurnRequest(sessionID: session, resume: false, budgetUSD: 1, prompt: "--dangerously-skip-permissions")
        ).arguments
        #expect(Array(args.suffix(2)) == ["--", "--dangerously-skip-permissions"])
        #expect(args.filter { $0 == "--" }.count == 1)
    }

    @Test func emptyOptionalListsOmitTheirFlags() throws {
        let config = try Config.parse("[tools]\navailable = [\"Read\"]")
        let args = try config.invocation(for: TurnRequest(sessionID: session, resume: false, budgetUSD: 1, prompt: "x")).arguments
        #expect(!args.contains("--allowedTools"))
        #expect(!args.contains("--disallowedTools"))
        #expect(!args.contains("--append-system-prompt"))
    }

    @Test func rejectsEmptyPromptAndBadBudget() throws {
        let config = try Config.parse(validConfig)
        #expect(throws: InvocationError.emptyPrompt) {
            try config.invocation(for: TurnRequest(sessionID: session, resume: false, budgetUSD: 1, prompt: " \n"))
        }
        #expect(throws: InvocationError.nonPositiveBudget) {
            try config.invocation(for: TurnRequest(sessionID: session, resume: false, budgetUSD: 0, prompt: "x"))
        }
    }

    @Test func displayCommandQuotesForHumans() throws {
        let config = try Config.parse(validConfig)
        let shown = try config.invocation(
            for: TurnRequest(sessionID: session, resume: false, budgetUSD: 1, prompt: "it's here")
        ).displayCommand
        #expect(shown.contains("'Bash(git status:*)'"))
        #expect(shown.hasSuffix("-- 'it'\\''s here'"))
    }
}

@Suite struct EnvironmentTests {
    @Test func onlyTheFixedNamesPlusEnvPassSurvive() throws {
        let config = try Config.parse("env_pass = [\"ANTHROPIC_API_KEY\"]\n[tools]\navailable = [\"Read\"]")
        let parent = [
            "PATH": "/usr/bin", "HOME": "/h", "USER": "u", "LOGNAME": "u", "CLAUDE_CONFIG_DIR": "/c",
            "LC_ALL": "en_US.UTF-8", "ANTHROPIC_API_KEY": "k",
            "SSH_AUTH_SOCK": "/s", "GITHUB_TOKEN": "t", "AWS_SECRET_ACCESS_KEY": "a", "NPM_TOKEN": "n",
        ]
        let child = config.childEnvironment(from: parent)
        #expect(Set(child.keys) == ["PATH", "HOME", "USER", "LOGNAME", "CLAUDE_CONFIG_DIR", "LC_ALL", "ANTHROPIC_API_KEY"])

        let strict = try Config.parse("[tools]\navailable = [\"Read\"]")
        #expect(strict.childEnvironment(from: parent)["ANTHROPIC_API_KEY"] == nil)
    }

    @Test func userAndLognameAreKept() {
        // Without them claude reports "Not logged in" under a scrubbed environment (task 4 smoke test).
        #expect(Config.baseEnvironmentNames.contains("USER"))
        #expect(Config.baseEnvironmentNames.contains("LOGNAME"))
    }
}

@Suite struct ExecutableResolverTests {
    @Test func findsOnPathAndRejectsMissing() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wb-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tool = dir.appendingPathComponent("faketool")
        try "#!/bin/sh\n".write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        let notExecutable = dir.appendingPathComponent("plain")
        try "x".write(to: notExecutable, atomically: true, encoding: .utf8)

        let path = "/nonexistent:\(dir.path)"
        #expect(ExecutableResolver.resolve("faketool", searchPath: path)?.path == tool.path)
        #expect(ExecutableResolver.resolve("plain", searchPath: path) == nil)
        #expect(ExecutableResolver.resolve("missing", searchPath: path) == nil)
        #expect(ExecutableResolver.resolve(tool.path, searchPath: nil)?.path == tool.path)
        #expect(ExecutableResolver.resolve("faketool", searchPath: nil) == nil)
    }
}

@Suite struct CheckingYourWorkPromptTests {
    private func goal() throws -> Goal {
        let text = """
            ---
            id: g-1
            title: T
            status: draft
            base: main
            budget_usd: 1
            turn_timeout_min: 5
            ---

            ## Request

            Do it.

            ## Criteria

            - [c1] It is done.
              - proof: a test

            ## Out of scope

            - Nothing else.
            """
        return try GoalFile.parse(text).goal
    }

    @Test func theFirstPromptPrefersANarrowCheckAndNamesTheFullOne() throws {
        let prompt = PromptBuilder.firstPrompt(goal: try goal(), checkCommand: "scripts/check.sh")
        let section = try #require(prompt.range(of: "## Checking your work"))
        let text = String(prompt[section.lowerBound...])
        #expect(text.contains("narrowest command you are allowed to run"))
        #expect(text.contains("`scripts/check.sh`"))
        #expect(text.contains("Workbench runs it itself when you finish"))
        #expect(text.contains("at most once, at the end"))
    }

    @Test func noCheckCommandMeansNoSection() throws {
        let prompt = PromptBuilder.firstPrompt(goal: try goal(), checkCommand: nil)
        #expect(!prompt.contains("## Checking your work"))
    }

    @Test func theRulesNameTheFullCheckWithoutForbiddingNarrowTests() {
        let rules = PromptBuilder.rules(checkCommand: "scripts/check.sh")
        #expect(rules.contains("The project's full check is `scripts/check.sh`"))
        #expect(!rules.contains("use exactly"))
    }
}
