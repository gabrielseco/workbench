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

    @Test(arguments: ["provider", "allowed_tools", "skills"])
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
}
