import Foundation
import Testing

@testable import WorkbenchCore

@Suite struct ConfigAutoAdviceTests {
    private static let stages = "stages = [\"pr-review\", \"design\"]\n"
    private static let designTable = "[review.stage.design]\nskill = \"d.md\"\n"

    private func parse(_ review: String) throws -> Config {
        try Config.parse("[tools]\navailable = [\"Read\"]\nallowed = [\"Read\"]\n[review]\n\(review)\n")
    }

    private func problems(_ review: String) -> [String] {
        do {
            _ = try parse(review)
            return []
        } catch let error as ConfigError { return error.problems.map(\.message) } catch { return ["\(error)"] }
    }

    @Test func autoIsOffByDefault() throws {
        #expect(try parse("").review.auto.isEmpty)
        #expect(try Config.parse("[tools]\navailable = [\"Read\"]\nallowed = [\"Read\"]\n").review.auto.isEmpty)
    }

    @Test func theJudgeAndAListedStageAreKeptInTheOrderGiven() throws {
        #expect(try parse(Self.stages + "auto = [\"design\", \"judge\"]\n" + Self.designTable).review.auto == ["design", "judge"])
        #expect(try parse("auto = [\"judge\"]").review.auto == ["judge"])
    }

    @Test(arguments: [
        ("auto = \"judge\"", "'auto' must be an array"),
        ("auto = [1]", "'auto' must contain only strings"),
        ("auto = [\"judge\", \"judge\"]", "more than once"),
        ("auto = [\"pr-review\"]", "cannot list 'pr-review'"),
        ("auto = [\"design\"]", "neither 'judge' nor a stage"),
    ])
    func anEntryThatCannotRunIsRefusedWithTheKeyNamed(review: String, message: String) {
        #expect(problems(review).contains { $0.contains(message) }, "\(problems(review))")
    }

    @Test func aStageCalledJudgeCannotBeAutoBecauseTheJudgeHasThatName() {
        let review = "stages = [\"pr-review\", \"judge\"]\nauto = [\"judge\"]\n[review.stage.judge]\nskill = \"j.md\"\n"
        #expect(problems(review).contains { $0.contains("also the name of a stage") }, "\(problems(review))")
    }

    @Test func aStageThatHasATableButIsNotListedIsRefused() {
        let review = "stages = [\"pr-review\"]\nauto = [\"design\"]\n" + Self.designTable
        #expect(problems(review).contains { $0.contains("neither 'judge' nor a stage") }, "\(problems(review))")
    }

    // MARK: auto_advance

    @Test func autoAdvanceIsOffByDefaultAndReadAsABoolean() throws {
        #expect(try parse("").review.autoAdvance == false)
        #expect(try parse("auto_advance = true").review.autoAdvance)
        #expect(try parse("auto_advance = false").review.autoAdvance == false)
    }

    @Test(arguments: ["auto_advance = \"yes\"", "auto_advance = 1", "auto_advance = [\"judge\"]"])
    func autoAdvanceThatIsNotABooleanIsRefusedWithTheKeyNamed(review: String) {
        #expect(problems(review).contains { $0.contains("'auto_advance' must be true or false") }, "\(problems(review))")
    }

    /// `[run]` is the table that starts the verifier's app: the switch lives under `[review]`, beside `auto`.
    @Test func aRunTableKeyOfThatNameIsNotTheSwitch() {
        let text = "[tools]\navailable = [\"Read\"]\nallowed = [\"Read\"]\n[run]\nauto_advance = true\n"
        #expect(throws: ConfigError.self) { try Config.parse(text) }
    }

    @Test func theAdviceIsAutoWhenItListsAnythingElseTheJudgeAndTheStagesWhenTheSwitchIsOn() throws {
        let off = try parse(Self.stages + Self.designTable)
        #expect(off.review.advice(goalAutoAdvance: nil).isEmpty)
        let on = try parse(Self.stages + "auto_advance = true\n" + Self.designTable)
        #expect(
            on.review.advice(goalAutoAdvance: nil) == ["judge", "design"], "pr-review reviews a pushed pull request: never")
        let onlyTheDefaultStage = try parse("auto_advance = true").review
        #expect(onlyTheDefaultStage.advice(goalAutoAdvance: nil) == ["judge"], "no stage but the default pr-review")
        let listed = try parse(Self.stages + "auto = [\"design\"]\nauto_advance = true\n" + Self.designTable)
        #expect(listed.review.advice(goalAutoAdvance: nil) == ["design"], "an explicit list wins: the switch adds nothing")
        #expect(listed.review.advice(goalAutoAdvance: false) == ["design"])
    }

    @Test func aGoalsOwnSwitchBeatsTheConfigs() throws {
        let on = try parse(Self.stages + "auto_advance = true\n" + Self.designTable).review
        let off = try parse(Self.stages + Self.designTable).review
        #expect(on.advice(goalAutoAdvance: false).isEmpty)
        #expect(off.advice(goalAutoAdvance: true) == ["judge", "design"])
        #expect(on.advice(goalAutoAdvance: true) == ["judge", "design"] && off.advice(goalAutoAdvance: false).isEmpty)
    }

    @Test func aStageNamedJudgeIsLeftOutOfTheSwitchsListAsAutoRefusesIt() throws {
        let review = "stages = [\"pr-review\", \"judge\", \"design\"]\nauto_advance = true\n"
            + "[review.stage.judge]\nskill = \"j.md\"\n" + Self.designTable
        let plan = try parse(review).review.advicePlan(goalAutoAdvance: nil)
        #expect(plan.names == ["judge", "design"], "the built-in judge once, not twice")
        #expect(plan.fromSwitch)
    }

    @Test func theAdviceSaysWhetherItCameFromTheSwitchOrFromAnAutoList() throws {
        #expect(try parse("auto = [\"judge\"]\nauto_advance = true").review.advicePlan(goalAutoAdvance: nil).fromSwitch == false)
        #expect(try parse("auto_advance = true").review.advicePlan(goalAutoAdvance: nil).fromSwitch)
    }
}
