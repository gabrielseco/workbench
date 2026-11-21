import Foundation
import Testing

@testable import WorkbenchCore

private let valid = """
    ---
    budget_usd: 40.00
    ---
    ## 1
    project: ~/rogal/backend
    goal: p1.md
    base: main

    ## 2
    project: ~/rogal/backend
    goal: p2.md
    base: after 1

    ## 3
    project: /work/frontend
    goal: p3.md
    after: 1, 2
    env: API_CONTRACT_REF=step:1, MODE=preview
    """

private func problems(_ text: String) -> [SeriesProblem] {
    do {
        _ = try SeriesDefinition.parse(text, name: "s")
        return []
    } catch let error as SeriesParseError {
        return error.problems
    } catch {
        return [SeriesProblem(line: nil, message: "\(error)")]
    }
}

struct SeriesFileTests {
    @Test func aValidSeriesParsesWithItsStepsAndEnv() throws {
        let series = try SeriesDefinition.parse(valid, name: "invoice")
        #expect(series.steps.count == 3)
        #expect(series.budgetUSD == 40)
        #expect(series.steps[0].base == .branch("main"))
        #expect(series.steps[1].base == .after(1))
        #expect(series.steps[1].after == [1])
        #expect(series.steps[2].after == [1, 2])
        #expect(series.steps[2].env.map(\.name) == ["API_CONTRACT_REF", "MODE"])
        #expect(series.steps[2].env[0].value == .stepBranch(1))
        #expect(series.steps[2].env[1].value == .literal("preview"))
    }

    @Test func aSeriesWithoutFrontMatterOrBudgetParses() throws {
        let series = try SeriesDefinition.parse("## 1\nproject: /a\ngoal: g.md\n", name: "s")
        #expect(series.budgetUSD == nil)
        #expect(series.steps[0].base == .branch(nil))
    }

    @Test func everyProblemIsReportedAtOnceWithItsLine() {
        let found = problems(
            """
            ---
            budget_usd: lots
            colour: red
            ---
            ## 1
            project: relative/path
            goal: ../escape.md
            base: after 1
            extra: x
            """)
        let text = found.map(\.description).joined(separator: "\n")
        #expect(text.contains("line 2: 'budget_usd' must be a positive number"))
        #expect(text.contains("line 3: unknown key 'colour'"))
        #expect(text.contains("step 1: 'project' must be an absolute path"))
        #expect(text.contains("step 1: 'goal' must be a file name"))
        #expect(text.contains("'base' names step 1, which does not come before this one"))
        #expect(text.contains("step 1: unknown key 'extra'"))
    }

    @Test func aForwardOrSelfReferenceIsRefusedSoThereIsNoCycle() {
        let text = problems(
            "## 1\nproject: /a\ngoal: a.md\nafter: 2\n## 2\nproject: /a\ngoal: b.md\nenv: X=step:2\n"
        ).map(\.description).joined(separator: "\n")
        #expect(text.contains("'after' names step 2, which does not come before this one"))
        #expect(text.contains("'env' names step 2, which does not come before this one"))
    }

    @Test func stepsAreNumberedInOrderWithNoGap() {
        let text = problems("## 1\nproject: /a\ngoal: a.md\n## 3\nproject: /a\ngoal: b.md\n").map(\.description).joined()
        #expect(text.contains("expected '## 2'"))
    }

    @Test func aMissingProjectOrGoalAndAnEmptySeriesAreRefused() {
        #expect(problems("## 1\ngoal: a.md\n").map(\.description).joined().contains("'project' is missing"))
        #expect(problems("## 1\nproject: /a\n").map(\.description).joined().contains("'goal' is missing"))
        #expect(problems("---\n---\n").map(\.description).joined().contains("no steps"))
    }

    @Test func projectPathsAndGoalNamesThatCouldReachSomewhereElseAreRefused() {
        for project in ["../a", "/a/../b", "-rf", "a", "/a\\b", "~/../b"] {
            #expect(!problems("## 1\nproject: \(project)\ngoal: a.md\n").isEmpty, "\(project)")
        }
        for goal in ["../a.md", "a/b.md", "a.txt", ".md", "series.md", "-a.md"] {
            #expect(!problems("## 1\nproject: /a\ngoal: \(goal)\n").isEmpty, "\(goal)")
        }
    }

    @Test func aDoubledSlashInAProjectPathIsAccepted() throws {
        let series = try SeriesDefinition.parse("## 1\nproject: /var/folders//T//x\ngoal: a.md\n", name: "s")
        #expect(series.steps[0].project == "/var/folders//T//x")
    }

    @Test func envNamesAndValuesAreChecked() {
        for env in ["lower=x", "A", "A=$(x)", "A=x y", "A=step:x", "A=x, A=y", "A=;b", "A=-x"] {
            #expect(!problems("## 1\nproject: /a\ngoal: a.md\nenv: \(env)\n").isEmpty, "\(env)")
        }
    }

    @Test func moreThanTheStepLimitIsRefused() {
        let text = (1...11).map { "## \($0)\nproject: /a\ngoal: g\($0).md\n" }.joined()
        #expect(problems(text).map(\.description).joined().contains("at most 10 steps"))
    }

    @Test func aBadNameIsRefused() {
        #expect(throws: SeriesParseError.self) { try SeriesDefinition.parse(valid, name: "../x") }
    }
}
