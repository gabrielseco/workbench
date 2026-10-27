import Foundation
import Testing

@testable import WorkbenchCore

private func goal() -> Goal {
    Goal(
        id: "g1", title: "mock engine", declaredStatus: .approved, base: "main", spend: .hardCap(5), turnTimeoutMin: 30,
        approvedAt: nil, approvedHash: nil, request: "Extract the engine.\n(Plan: names are a suggestion)",
        criteria: [Criterion(id: "c1", text: "Isolation holds.", proof: "isolation test")],
        outOfScope: ["Editing vendor/"], contentHash: "h")
}

private func encoded(_ object: [String: Any]) -> String {
    // swiftlint:disable:next force_try
    String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
}

private func answer(_ object: [String: Any], isError: Bool = false) -> String {
    encoded(["type": "result", "is_error": isError, "result": encoded(object)])
}

private func fenced(_ inner: String) -> String {
    encoded(["type": "result", "is_error": false, "result": "Here it is:\n```json\n\(inner)\n```"])
}

@Suite struct PRDescriberTests {
    // MARK: Answer

    @Test func readsTheStructuredAnswer() throws {
        let raw = answer([
            "title": "feat(mocks): extract a mock engine", "summary": "Adds the engine.\n\nSecond paragraph.",
            "decisions": ["Strict replay by default."], "deviations": [],
        ])
        let d = try PRDescriber.parse(output: raw)
        #expect(d.title == "feat(mocks): extract a mock engine")
        #expect(d.summary == "Adds the engine.\n\nSecond paragraph.")
        #expect(d.decisions == ["Strict replay by default."])
        #expect(d.deviations.isEmpty)
    }

    @Test func toleratesAFenceAroundTheObject() throws {
        let raw = fenced(#"{"title": "fix(ship): x", "summary": "s"}"#)
        let d = try PRDescriber.parse(output: raw)
        #expect(d.title == "fix(ship): x" && d.decisions.isEmpty && d.deviations.isEmpty)
    }

    @Test(arguments: [
        ("not json at all", "not JSON"),
        (#"{"type":"result","is_error":false}"#, "no result"),
        (#"{"type":"result","is_error":false,"result":"just words"}"#, "not a JSON object"),
    ])
    func rejectsOutputThatIsNotTheObject(raw: String, why: String) {
        #expect(throws: PRDescribeError.self) { try PRDescriber.parse(output: raw) }
        do { _ = try PRDescriber.parse(output: raw) } catch { #expect("\(error)".contains(why)) }
    }

    @Test func rejectsAnErrorResult() {
        let raw = answer(["title": "t", "summary": "s"], isError: true)
        #expect(throws: PRDescribeError.self) { try PRDescriber.parse(output: raw) }
    }

    @Test(arguments: [
        ["summary": "s"],
        ["title": "", "summary": "s"],
        ["title": "line one\nline two", "summary": "s"],
        ["title": "t"],
        ["title": "t", "summary": "   "],
    ])
    func rejectsAnUnusableTitleOrSummary(object: [String: String]) {
        #expect(throws: PRDescribeError.self) { try PRDescriber.parse(output: answer(object)) }
    }

    @Test func anOverLongTitleIsCutAtAWordNotRefused() throws {
        let long = "feat(inbox): order bot findings first for your own PRs and hide the fix actions on others' PRs"
        #expect(long.count > PRDescriber.titleLimit)
        let d = try PRDescriber.parse(output: answer(["title": long, "summary": "the summary", "why": "the why"]))
        #expect(d.title.count <= PRDescriber.titleLimit)
        #expect(d.title.hasPrefix("feat(inbox): order bot findings"))
        #expect(long.hasPrefix(d.title + " "), "cut between words: \(d.title)")
        #expect(d.summary == "the summary" && d.why == "the why", "the rest of the answer is kept")
    }

    @Test func aLongTitleWithNoSpaceIsCutAtTheLimit() throws {
        let d = try PRDescriber.parse(output: answer(["title": String(repeating: "a", count: 73), "summary": "s"]))
        #expect(d.title.count == PRDescriber.titleLimit)
    }

    @Test func rejectsListsThatAreNotStrings() {
        let raw = answer(["title": "t", "summary": "s", "decisions": [1, 2]])
        #expect(throws: PRDescribeError.self) { try PRDescriber.parse(output: raw) }
    }

    @Test func acceptsATitleOfExactlyTheLimit() throws {
        let title = String(repeating: "a", count: PRDescriber.titleLimit)
        #expect(try PRDescriber.parse(output: answer(["title": title, "summary": "s"])).title == title)
    }

    @Test func capsTheListsAtEightItems() throws {
        let many = (1...12).map { "item \($0)" }
        let d = try PRDescriber.parse(output: answer(["title": "t", "summary": "s", "decisions": many]))
        #expect(d.decisions.count == 3)
    }

    // MARK: Request

    @Test func theTurnHasNoToolsAndItsOwnSession() throws {
        let config = try Config.parse("[tools]\navailable = [\"Read\", \"Edit\", \"Bash\"]\nallowed = [\"Read\"]\n")
        let args = PRDescriber.arguments(config: config, prompt: "the prompt")
        let tools = try #require(args.firstIndex(of: "--tools"))
        #expect(args[tools + 1] == "")
        #expect(!args.contains("--allowedTools") && !args.contains("--resume"))
        #expect(args.contains("--session-id"))
        #expect(args.last == "the prompt")
        #expect(args.contains("--max-budget-usd"))
        #expect(!PRDescriber.displayArguments(args).contains("the prompt"))
    }

    @Test func theModelAndEffortComeFromTheShipTableOnly() throws {
        func args(_ toml: String) throws -> [String] {
            PRDescriber.arguments(config: try Config.parse(toml + "[tools]\navailable = [\"Read\"]\n"), prompt: "p")
        }
        func value(_ flag: String, _ args: [String]) -> String? { args.firstIndex(of: flag).map { args[$0 + 1] } }
        let set = try args("[agents.run]\nmodel = \"opus\"\n[agents.ship]\nmodel = \"haiku\"\nreasoning_effort = \"low\"\n")
        #expect(value("--model", set) == "haiku" && value("--effort", set) == "low")
        #expect(set.firstIndex(of: "--model")! < set.firstIndex(of: "--")!)
        // Without [agents.ship] the CLI's default: the coding model is not inherited.
        let unset = try args("[agents.run]\nmodel = \"opus\"\n")
        #expect(!unset.contains("--model") && !unset.contains("--effort"))
        #expect(try !args("").contains("--model"))
    }

    @Test func thePromptCarriesEverythingAndNoLocalPaths() {
        let check = Review.Check(
            turn: 1, result: "passed", exitCode: 0, durationMs: 4000, outputRef: nil, command: "scripts/check.sh")
        let input = PRDescribeInput(
            goal: goal(), notes: ["remove vendor/ please"], turnResult: "Done. See /Users/dev/project/x.ts",
            commits: ["feat: extract engine"], diff: "+let a = 1", diffTruncated: true, check: check)
        let prompt = PRDescriber.prompt(for: input)
        for needle in [
            "mock engine", "Extract the engine.", "Isolation holds.", "Editing vendor/", "remove vendor/ please",
            "feat: extract engine", "+let a = 1", "Check: passed", "cut at",
        ] { #expect(prompt.contains(needle), "missing \(needle)") }
        #expect(!prompt.contains("/Users/dev"))
    }

    // MARK: Rendering

    @Test func theModelCannotTickACriterionOrInventACheck() {
        let d = PRDescription(
            title: "feat(mocks): extract a mock engine", summary: "All criteria pass and the check passed.",
            decisions: ["Strict replay."], deviations: ["Added a toolchain."])
        let body = PRBodyBuilder.build(goal: goal(), check: nil, template: nil, description: d)
        #expect(body.title == "feat(mocks): extract a mock engine")
        #expect(body.body.contains("All criteria pass and the check passed."))
        #expect(body.body.contains("### Decisions to review") && body.body.contains("- Strict replay."))
        #expect(body.body.contains("### Differences from the goal") && body.body.contains("- Added a toolchain."))
        #expect(body.body.contains("Check: not run"))
        #expect(body.body.contains("- [ ] Isolation holds."))
        #expect(!body.body.contains("(Plan:"))
    }

    @Test func aTemplateStillGetsItsHeadings() {
        let template = "## Summary\n\n## Testing\n\n- [ ] tests\n"
        let d = PRDescription(title: "fix: a", summary: "Did a.", decisions: [], deviations: [])
        let body = PRBodyBuilder.build(goal: goal(), check: nil, template: template, description: d).body
        let summary = body.range(of: "## Summary")
        let testing = body.range(of: "## Testing")
        #expect(summary != nil && testing != nil && body.contains("Did a."))
        if let summary, let testing { #expect(summary.lowerBound < testing.lowerBound) }
    }

    @Test func theModelsTextIsScrubbedLikeTheGoals() {
        let d = PRDescription(
            title: "fix: a", summary: "Edited /Users/dev/rogal/x/y.swift and ~/notes/z.", decisions: [],
            deviations: ["see .workbench/threads/g/events.jsonl"])
        let body = PRBodyBuilder.build(goal: goal(), check: nil, template: nil, description: d).body
        #expect(!body.contains("/Users/dev") && !body.contains("~/notes") && !body.contains(".workbench/threads"))
        #expect(body.contains("<path>"))
    }

    @Test func withoutADescriptionTheBodyIsUnchanged() {
        let plain = PRBodyBuilder.build(goal: goal(), check: nil, template: nil)
        let explicit = PRBodyBuilder.build(goal: goal(), check: nil, template: nil, description: nil)
        #expect(plain == explicit)
        #expect(plain.title == "mock engine")
    }

    @Test func whyIsReadAndTrimmed() throws {
        let d = try PRDescriber.parse(output: answer(["title": "t", "summary": "s", "why": "  The retry was missing.  "]))
        #expect(d.why == "The retry was missing.")
        #expect(try PRDescriber.parse(output: answer(["title": "t", "summary": "s"])).why == "")
    }

    @Test func aWhyThatIsNotAStringOrIsTooLongIsRefused() {
        for why: Any in [5, String(repeating: "a", count: PRDescriber.whyLimit + 1)] {
            #expect(throws: PRDescribeError.self) {
                try PRDescriber.parse(output: answer(["title": "t", "summary": "s", "why": why]))
            }
        }
    }

    @Test func aSummaryOverTheLimitIsRefused() {
        let long = String(repeating: "a", count: PRDescriber.summaryLimit + 1)
        #expect(throws: PRDescribeError.self) {
            try PRDescriber.parse(output: answer(["title": "t", "summary": long]))
        }
        #expect(throws: Never.self) {
            try PRDescriber.parse(
                output: answer(["title": "t", "summary": String(repeating: "a", count: PRDescriber.summaryLimit)]))
        }
    }
}
