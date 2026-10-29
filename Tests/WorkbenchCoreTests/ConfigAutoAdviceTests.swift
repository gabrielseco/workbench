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
}
