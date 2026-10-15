import Foundation
import Testing

@testable import WorkbenchCore

let sampleBody = """
    ## Summary

    Moves five countries to their latest version.

    ## Why

    These five countries were behind.

    ## What changed

    <details>
    <summary>Toggle details</summary>

    | Country | From | To |
    | ------- | ---- | -- |
    | Portugal (PRT) | v3 | v9 |

    ```md
    ## not a heading
    ```

    </details>

    ## Testing

    - [ ] Tested in a browser

    🤖 Generated with [Claude Code](https://claude.com/claude-code)

    <!-- CURSOR_SUMMARY -->
    ---

    > [!NOTE]
    > **Low Risk**
    >
    ## Overview inside the bot block

    <sup>Reviewed by Bugbot</sup>
    <!-- /CURSOR_SUMMARY -->
    """

private func parts(_ body: String) -> [String] {
    PRBodyRefresher.parts(of: body).map { ($0.heading ?? "") + "\n" + $0.lines.joined(separator: "\n") }
}

@Suite struct PRBodyRefresherTests {
    @Test func noEditsLeavesTheBodyByteForByte() throws {
        let same = try PRBodyRefresher.apply(PRRefresh(title: "t", sections: [:]), to: sampleBody)
        #expect(same == sampleBody)
    }

    @Test func onlyTheNamedSectionChangesAndEveryOtherLineStays() throws {
        let edited = try PRBodyRefresher.apply(
            PRRefresh(title: "t", sections: ["summary": "Moves four countries to their latest version."]), to: sampleBody)
        #expect(edited.contains("Moves four countries"))
        #expect(!edited.contains("Moves five countries"))
        let before = parts(sampleBody)
        let after = parts(edited)
        #expect(before.count == after.count)
        for (index, pair) in zip(before, after).enumerated() where index != 1 { #expect(pair.0 == pair.1, "part \(index)") }
    }

    @Test func aBotBlockInsideAnEditedSectionIsKeptVerbatimAtTheEnd() throws {
        let range = try #require(
            sampleBody.range(of: "<!-- CURSOR_SUMMARY -->[\\s\\S]*<!-- /CURSOR_SUMMARY -->", options: .regularExpression))
        let block = String(sampleBody[range])
        let edited = try PRBodyRefresher.apply(
            PRRefresh(title: "t", sections: ["testing": "- [x] Tested in a browser"]), to: sampleBody)
        #expect(edited.contains(block))
        #expect(edited.hasSuffix(block))
        #expect(edited.contains("- [x] Tested in a browser"))
        #expect(!edited.contains("- [ ] Tested in a browser"))
    }

    @Test func theModelNeverSeesABotBlockAndAHeadingInsideOneIsNotASection() {
        let sections = PRBodyRefresher.editable(in: sampleBody)
        #expect(sections.map(\.name) == ["summary", "why", "what changed", "testing"])
        let testing = sections.first { $0.name == "testing" }?.content ?? ""
        #expect(!testing.contains("CURSOR_SUMMARY") && !testing.contains("Overview inside the bot block"))
        #expect(testing.hasSuffix("🤖 Generated with [Claude Code](https://claude.com/claude-code)"))
    }

    @Test func aHeadingInsideFencedCodeIsNotASection() {
        let names = PRBodyRefresher.editable(in: sampleBody).map(\.name)
        #expect(!names.contains("not a heading"))
    }

    @Test(arguments: [
        ("nope", "x", PRRefreshError.unknownSection("nope")),
        ("summary", "   \n", PRRefreshError.emptySection("summary")),
        ("summary", "text\n## Extra\nmore", PRRefreshError.headingInContent("summary")),
        ("summary", "text <!-- BOT -->x<!-- /BOT -->", PRRefreshError.blockInContent("summary")),
        ("summary", String(repeating: "a", count: PRBodyRefresher.sectionLimit + 1), PRRefreshError.tooLong("summary")),
    ])
    func badEditsAreRefusedBeforeAnythingChanges(name: String, text: String, expected: PRRefreshError) {
        do {
            _ = try PRBodyRefresher.apply(PRRefresh(title: "t", sections: [name: text]), to: sampleBody)
            Issue.record("expected \(expected)")
        } catch let error as PRRefreshError { #expect(error == expected) } catch { Issue.record("\(error)") }
    }

    @Test(arguments: [
        "## A\n\nBefore <!-- BOT -->x<!-- /BOT --> after\n\n## B\n\nb\n",
        "## A\n\none\n\n<!-- BOT -->x<!-- /BOT -->\n\ntwo\n\n## B\n\nb\n",
        "## A\n\nTitle\n=====\n\ntext\n\n## B\n\nb\n",
        "## A\n\ntext\n---\nmore\n\n## B\n\nb\n",
        "## A\n\n  ## Indented\n\ntext\n\n## B\n\nb\n",
    ])
    func aSectionThatCannotBeRewrittenWholeIsLeftForAPerson(body: String) {
        #expect(PRBodyRefresher.editable(in: body).map(\.name) == ["b"])
        do {
            _ = try PRBodyRefresher.apply(PRRefresh(title: "t", sections: ["a": "new"]), to: body)
            Issue.record("expected a refusal")
        } catch let error as PRRefreshError { #expect(error == .notEditable("a")) } catch { Issue.record("\(error)") }
    }

    @Test(arguments: ["text\n  ## Extra\nmore", "Extra\n-----\nmore", "Extra\n=====", "text\n### Deep"])
    func everyMarkdownHeadingFormIsRefusedInNewText(text: String) {
        let body = "## A\n\nold\n\n## B\n\nb\n"
        do {
            _ = try PRBodyRefresher.apply(PRRefresh(title: "t", sections: ["a": text]), to: body)
            Issue.record("expected a refusal")
        } catch let error as PRRefreshError { #expect(error == .headingInContent("a")) } catch { Issue.record("\(error)") }
    }

    @Test func aTableSeparatorOrAThematicBreakAfterABlankLineIsNotAHeading() throws {
        let body = "## A\n\nold\n\n## B\n\nb\n"
        let text = "| a | b |\n| --- | --- |\n| 1 | 2 |\n\n---\n\nend"
        let edited = try PRBodyRefresher.apply(PRRefresh(title: "t", sections: ["a": text]), to: body)
        #expect(edited.contains("| --- | --- |"))
    }

    @Test func aBodyWithWindowsLineEndingsKeepsEveryUntouchedByte() throws {
        let body = sampleBody.replacingOccurrences(of: "\n", with: "\r\n")
        #expect(try PRBodyRefresher.apply(PRRefresh(title: "new title", sections: [:]), to: body) == body)

        let edited = try PRBodyRefresher.apply(
            PRRefresh(title: "t", sections: ["summary": "Four countries.\n\nSecond paragraph."]), to: body)
        #expect(edited.contains("Four countries.\r\n\r\nSecond paragraph.\r\n"))
        #expect(!edited.replacingOccurrences(of: "\r\n", with: "").contains("\n"), "no bare LF was introduced")
        let before = PRBodyRefresher.parts(of: body).map { ($0.heading ?? "") + $0.lines.joined(separator: "\n") }
        let after = PRBodyRefresher.parts(of: edited).map { ($0.heading ?? "") + $0.lines.joined(separator: "\n") }
        for (index, pair) in zip(before, after).enumerated() where index != 1 { #expect(pair.0 == pair.1, "part \(index)") }
        #expect(PRBodyRefresher.editable(in: edited).first { $0.name == "summary" }?.content
            == "Four countries.\n\nSecond paragraph.")
    }

    @Test func anEditThatEndsABodyWithoutATrailingNewlineAddsNone() throws {
        let body = "## A\r\n\r\nold\r\n\r\n## B\r\n\r\nlast"
        let edited = try PRBodyRefresher.apply(PRRefresh(title: "t", sections: ["b": "new last"]), to: body)
        #expect(edited == "## A\r\n\r\nold\r\n\r\n## B\r\n\r\nnew last")
    }

    @Test func twoSectionsWithTheSameNameCannotBeEdited() {
        let body = "## Notes\n\none\n\n## Notes\n\ntwo\n"
        do {
            _ = try PRBodyRefresher.apply(PRRefresh(title: "t", sections: ["notes": "x"]), to: body)
            Issue.record("expected a refusal")
        } catch let error as PRRefreshError { #expect(error == .ambiguousSection("notes")) } catch { Issue.record("\(error)") }
    }
}

private func input(body: String = sampleBody, title: String = "chore: bump five countries") -> PRRefreshInput {
    let goal = try! GoalFile.parse(
        """
        ---
        id: g-2026-10-15-x
        title: x
        base: main
        budget_usd: 5.00
        turn_timeout_min: 30
        ---

        ## Request

        Leave PRT out.

        ## Criteria

        - [c1] PRT is back to main.
          - proof: git diff

        ## Out of scope

        - Other countries.
        """
    ).goal
    return PRRefreshInput(
        goal: goal, notes: [], turnResult: nil, commits: ["chore: leave PRT out"], diff: "-PRT: 9\n+PRT: 3",
        diffTruncated: false, check: nil, current: PRText(title: title, body: body))
}

func answer(_ json: String) -> String {
    let escaped = json.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    return "{\"result\": \"\(escaped)\"}"
}

@Suite struct PRRefresherTests {
    @Test func thePromptCarriesTheCurrentTextTheNewWorkAndNoBotBlock() {
        let prompt = PRRefresher.prompt(for: input())
        #expect(prompt.contains("chore: bump five countries"))
        #expect(prompt.contains("## Section: summary") && prompt.contains("## Section: what changed"))
        #expect(prompt.contains("Moves five countries"))
        #expect(prompt.contains("Leave PRT out."))
        #expect(prompt.contains("-PRT: 9"))
        #expect(!prompt.contains("CURSOR_SUMMARY") && !prompt.contains("Reviewed by Bugbot"))
    }

    @Test func aValidAnswerKeepsOnlyTheSectionsThatReallyChange() throws {
        let current = PRText(title: "chore: bump five countries", body: sampleBody)
        let json =
            #"{"title": "chore: bump four countries", "sections": {"#
            + #""Summary": "Moves four countries to their latest version.", "#
            + #""Why": "These five countries were behind."}}"#
        let refresh = try PRRefresher.parse(output: answer(json), current: current)
        #expect(refresh.title == "chore: bump four countries")
        #expect(refresh.sections == ["summary": "Moves four countries to their latest version."])
    }

    @Test(arguments: [
        "not json",
        #"{"title": "", "sections": {}}"#,
        #"{"title": "a\nb", "sections": {}}"#,
        #"{"title": "chore: x", "sections": {"Nope": "x"}}"#,
        #"{"title": "chore: x", "sections": {"Summary": 3}}"#,
        #"{"title": "chore: x", "sections": ["Summary"]}"#,
    ])
    func anUnusableAnswerIsRefused(json: String) {
        let current = PRText(title: "chore: bump five countries", body: sampleBody)
        #expect(throws: PRDescribeError.self) { try PRRefresher.parse(output: answer(json), current: current) }
    }

    @Test func aTitleOverTheLimitIsRefusedUnlessItIsTheCurrentOne() throws {
        let long = String(repeating: "x", count: PRBodyBuilder.titleLimit + 5)
        let current = PRText(title: long, body: sampleBody)
        #expect(throws: PRDescribeError.self) {
            try PRRefresher.parse(output: answer(#"{"title": "\#(long)y", "sections": {}}"#), current: current)
        }
        let same = try PRRefresher.parse(output: answer(#"{"title": "\#(long)", "sections": {}}"#), current: current)
        #expect(same.title == long && same.sections.isEmpty)
    }
}
