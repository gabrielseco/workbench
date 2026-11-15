import Foundation
import Testing

@testable import WorkbenchCore

private let tools = "[tools]\navailable = [\"Read\"]\n"

private func parse(_ verifier: String, root: String = "") throws -> Config {
    try Config.parse(root + "\n" + tools + "\n" + verifier)
}

private func problems(_ verifier: String, root: String = "") -> [ConfigProblem] {
    do {
        _ = try parse(verifier, root: root)
        return []
    } catch let error as ConfigError {
        return error.problems
    } catch {
        Issue.record("unexpected error \(error)")
        return []
    }
}

@Suite struct VerifierConfigTests {
    @Test func noTableMeansTheDefaultVerifier() throws {
        let config = try Config.parse(tools)
        #expect(config.verifier == VerifierConfig())
        #expect(config.verifier?.skill == ".claude/skills/verify/SKILL.md")
        #expect(config.verifierModel == nil)
    }

    @Test func enabledFalseTurnsTheVerifierOff() throws {
        #expect(try parse("[verifier]\nenabled = false").verifier == nil)
        #expect(try parse("[verifier]\nenabled = true\nmodel = \"sonnet\"").verifier?.model == "sonnet")
        #expect(problems("[verifier]\nenabled = \"no\"").map(\.code) == [.wrongType])
    }

    @Test func autoIsGoneAndNamedAsUnknown() {
        let found = problems("[verifier]\nauto = true")
        #expect(found.first?.message == "unknown key 'auto' in [verifier]")
    }

    @Test func aMinimalTableTakesThePlansDefaults() throws {
        let config = try parse("[verifier]\nskill = \".claude/skills/verify/SKILL.md\"")
        let verifier = try #require(config.verifier)
        #expect(verifier.skill == ".claude/skills/verify/SKILL.md")
        #expect(verifier.tools == ["Read"])
        #expect(verifier.model == nil)
        #expect(verifier.budgetUSD == 1)
        #expect(verifier.timeoutMin == 10)
    }

    @Test func everyKeyIsRead() throws {
        let config = try parse(
            """
            [verifier]
            skill = ".agents/skills/verify/SKILL.md"
            model = "sonnet"
            budget_usd = 2.5
            timeout_min = 20
            tools = ["Read", "Bash(scripts/verify-app.sh:*)", "Bash(swift scripts/ax.swift:*)"]
            """)
        let verifier = try #require(config.verifier)
        #expect(verifier.skill == ".agents/skills/verify/SKILL.md")
        #expect(verifier.model == "sonnet")
        #expect(verifier.budgetUSD == Decimal(string: "2.5"))
        #expect(verifier.timeoutMin == 20)
        #expect(verifier.tools == ["Read", "Bash(scripts/verify-app.sh:*)", "Bash(swift scripts/ax.swift:*)"])
    }

    @Test func theModelIsItsOwnElseTheCLIDefaultNeverTheCodingModel() throws {
        let skill = "[verifier]\nskill = \"s.md\""
        let run = "[agents.run]\nmodel = \"opus\"\n"
        #expect(try parse(run + skill).verifierModel == nil)
        #expect(try parse(run + skill + "\nmodel = \"sonnet\"").verifierModel == "sonnet")
        #expect(try parse(skill).verifierModel == nil)
    }

    @Test(arguments: ["Bash", "Bash(*)", "Bash(:*)", "Bash(*:*)", "Bash( * )"])
    func aBashWithNoCommandToConfineItIsRefused(pattern: String) {
        let found = problems("[verifier]\nskill = \"s.md\"\ntools = [\"Read\", \"\(pattern)\"]")
        #expect(found.map(\.code) == [.invalidValue], "\(found)")
        #expect(found.first?.message.contains("'tools' entry '\(pattern)'") == true)
    }

    @Test(arguments: ["Bash(git status:*)", "Bash(scripts/snap.sh:*)", "Read", "Glob"])
    func aNamedHelperIsAccepted(pattern: String) {
        #expect(problems("[verifier]\nskill = \"s.md\"\ntools = [\"\(pattern)\"]").isEmpty)
    }

    @Test func aToolThatIsNotAPatternIsRefused() {
        #expect(problems("[verifier]\nskill = \"s.md\"\ntools = [\"not a tool!\"]").map(\.code) == [.invalidValue])
    }

    @Test func noToolsAtAllIsRefused() {
        #expect(problems("[verifier]\nskill = \"s.md\"\ntools = []").map(\.code) == [.invalidValue])
    }

    @Test func theSkillMayBeLeftOutButNotEmpty() {
        #expect(problems("[verifier]\nmodel = \"sonnet\"").isEmpty)
        let empty = problems("[verifier]\nskill = \"\"")
        #expect(empty.map(\.code) == [.invalidValue])
        #expect(empty.first?.message.contains("'skill'") == true)
    }

    @Test(arguments: ["/etc/passwd", "~/skill.md", "../outside.md", "a/../../b.md", "a//b.md", "-flag.md"])
    func aSkillPathOutsideTheRepositoryIsRefused(path: String) {
        let found = problems("[verifier]\nskill = \"\(path)\"")
        #expect(found.map(\.code) == [.invalidValue], "\(found)")
        #expect(found.first?.message.contains("'skill'") == true)
    }

    @Test(arguments: ["./.claude/skills/verify/SKILL.md", ".claude/./skills/SKILL.md", "skills/SKILL.md/."])
    func aDotPartInTheSkillPathIsRefused(path: String) {
        let found = problems("[verifier]\nskill = \"\(path)\"")
        #expect(found.map(\.code) == [.invalidValue], "\(found)")
        #expect(found.first?.message.contains("'skill' must be a path without '.' parts") == true)
    }

    @Test(arguments: ["allowed_tools", "skills"])
    func anUnknownKeyIsRefusedWithItsName(key: String) {
        let found = problems("[verifier]\nskill = \"s.md\"\n\(key) = \"codex\"")
        #expect(found.map(\.code) == [.unknownKey])
        #expect(found.first?.message == "unknown key '\(key)' in [verifier]")
    }

    @Test func wrongTypesAndBoundsAreRefused() {
        let base = "[verifier]\nskill = \"s.md\"\n"
        #expect(problems(base + "enabled = \"yes\"").map(\.code) == [.wrongType])
        #expect(problems(base + "model = 3").map(\.code) == [.wrongType])
        #expect(problems(base + "model = \"has space\"").map(\.code) == [.invalidValue])
        #expect(problems(base + "tools = \"Read\"").map(\.code) == [.wrongType])
        #expect(problems(base + "tools = [\"Read\", 3]").map(\.code) == [.wrongType])
        #expect(problems("[verifier]\nskill = 3").map(\.code) == [.wrongType])
        for bad in ["0", "-1", "\"1\""] {
            #expect(problems(base + "budget_usd = \(bad)").map(\.code) == [.invalidValue])
        }
        for bad in ["0", "241", "1.5", "\"10\""] {
            #expect(problems(base + "timeout_min = \(bad)").map(\.code) == [.invalidValue])
        }
    }

    @Test func aSecondVerifierTableIsNotAReviewStage() {
        #expect(problems("[verifier.extra]\nskill = \"s.md\"").map(\.code) == [.unknownTable])
    }

    private func argv(_ root: String, verifier: String = "") throws -> [String] {
        let config = try parse(verifier, root: root)
        return Verifier.arguments(
            config: config, verifier: try #require(config.verifier), prompt: "p", proofDirectory: URL(fileURLWithPath: "/proof"))
    }

    @Test func autoPermissionsLetTheVerifierUseBashWithoutListingHelpers() throws {
        let auto = try argv("permissions = \"auto\"")
        #expect(auto.contains("--permission-mode") && auto[auto.firstIndex(of: "--permission-mode")! + 1] == "auto")
        let tools = auto[(auto.firstIndex(of: "--tools")! + 1)...].prefix { !$0.hasPrefix("--") }
        #expect(Array(tools) == ["Read", "Bash"])
    }

    @Test func autoPermissionsKeepADeniedToolDeniedAndTheListedToolsAllowed() throws {
        let tools = "[tools]\navailable = [\"Read\"]\ndenied = [\"Bash(rm:*)\"]\n"
        let config = try Config.parse(
            "permissions = \"auto\"\n" + tools + "\n[verifier]\ntools = [\"Read\", \"Bash(scripts/v.sh:*)\"]")
        let args = Verifier.arguments(
            config: config, verifier: try #require(config.verifier), prompt: "p", proofDirectory: URL(fileURLWithPath: "/proof"))
        #expect(args.contains("Bash(rm:*)") && args.contains("Bash(scripts/v.sh:*)"))
        #expect(args.filter { $0 == "Bash" }.count == 1)
    }

    @Test func theAllowlistModeStaysWithoutBashOrAutoMode() throws {
        let args = try argv("")
        #expect(!args.contains("--permission-mode") && !args.contains("Bash"))
    }

    // MARK: the Codex verifier's sandbox

    @Test func aCodexVerifierRunsWithoutASandboxAndWithoutTheUsersCodexSetup() {
        func value(_ args: [String], after flag: String) -> String? { args.firstIndex(of: flag).map { args[$0 + 1] } }
        let args = Verifier.codexArguments(
            verifier: VerifierConfig(model: "m", provider: .codex), prompt: "p", worktree: URL(fileURLWithPath: "/wt"),
            answerFile: URL(fileURLWithPath: "/answer"))
        #expect(value(args, after: "-s") == "danger-full-access")
        #expect(!args.contains { $0.hasPrefix("sandbox_workspace_write.") } && !args.contains("workspace-write"))
        // What the user's Codex setup could add is still left out, and nothing asks for approval.
        #expect(args.contains("--ignore-user-config") && args.contains("--ignore-rules"))
        #expect(args.contains("approval_policy=\"never\""))
        #expect(value(args, after: "-m") == "m" && value(args, after: "-C") == "/wt")
        #expect(value(args, after: "-o") == "/answer" && args.last == "p")
    }

    @Test func screenshotsTheGoalNamesThatAreNotInTheProofAreReportedMissing() throws {
        let goal = try GoalFile.parse(
            """
            ---
            id: g-1
            title: T
            base: main
            budget_usd: 1
            turn_timeout_min: 5
            ---

            ## Request

            Do it.

            ## Criteria

            - [c1] a
              - proof: screenshot: one, two
            - [c2] b
              - proof: screenshot: two
            - [c3] c
              - proof: `scripts/check-changed.sh`

            ## Out of scope

            - none
            """
        ).goal
        #expect(Verifier.missingScreenshots(goal: goal, present: []) == ["one.png", "two.png"])
        #expect(Verifier.missingScreenshots(goal: goal, present: ["one.png"]) == ["two.png"])
        #expect(Verifier.missingScreenshots(goal: goal, present: ["one.png", "two.png", "other.png"]).isEmpty)
    }
}
