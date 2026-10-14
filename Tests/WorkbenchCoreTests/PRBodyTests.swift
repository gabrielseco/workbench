import Foundation
import Testing

@testable import WorkbenchCore

private func goal(
    title: String = "Add retry with backoff",
    request: String = "Add retry to `SyncClient.fetch`.",
    criteria: [Criterion] = [
        Criterion(id: "c1", text: "Retries on 5xx, not 4xx.", proof: "test `SyncClientTests.retries*`"),
        Criterion(id: "c2", text: "Delay is capped at 30s.", proof: "unit test with injected clock"),
    ]
) -> Goal {
    Goal(
        id: "g1", title: title, declaredStatus: .approved, base: "main", budgetUSD: 5, turnTimeoutMin: 30,
        approvedAt: nil, approvedHash: nil, request: request, criteria: criteria, outOfScope: [],
        contentHash: "h")
}

private func check(_ result: String, exit: Int? = 0, ms: Int? = 12_000) -> Review.Check {
    Review.Check(turn: 1, result: result, exitCode: exit, durationMs: ms, outputRef: "checks/turn-1.log")
}

private let repoTemplate = """
    <!-- Title: Conventional Commits. A squash merge keeps it. -->

    ## Summary

    <!-- What changes, in a few sentences. -->

    ## Why

    <!-- The task or problem. -->

    ## What changed

    <details>
    <summary>Files and behaviour</summary>

    <!-- Per area, short. -->

    </details>

    ## Testing

    - [ ] `scripts/check.sh` passes
    - [ ] Docs and spec updated, if behaviour changed
    """

@Suite struct PRBodyTests {
    @Test func listsRequestAndEveryCriterionInOrder() {
        let out = PRBodyBuilder.build(goal: goal(), check: check("passed"), template: nil)
        let body = out.body
        #expect(body.contains("Add retry to `SyncClient.fetch`."))
        let first = body.range(of: "- [ ] Retries on 5xx, not 4xx.")
        let second = body.range(of: "- [ ] Delay is capped at 30s.")
        #expect(first != nil && second != nil)
        if let first, let second { #expect(first.lowerBound < second.lowerBound) }
        #expect(body.contains("proven by: test `SyncClientTests.retries*`"))
    }

    @Test func noTemplateUsesTheFixedLayout() {
        let body = PRBodyBuilder.build(goal: goal(), check: check("passed"), template: nil).body
        let headings = body.split(separator: "\n").filter { $0.hasPrefix("## ") }
        #expect(headings == ["## Summary", "## Criteria", "## Check"])
        #expect(body.hasSuffix("Check: passed (exit 0, 12s)\n"))
    }

    @Test func blankTemplateIsTreatedAsNone() {
        let body = PRBodyBuilder.build(goal: goal(), check: nil, template: "  \n\n").body
        #expect(body.contains("## Criteria"))
    }

    @Test func titleIsTheGoalTitle() {
        #expect(PRBodyBuilder.build(goal: goal(), check: nil, template: nil).title == "Add retry with backoff")
    }

    @Test func longTitleIsCutOnAWordBoundary() {
        let long = String(repeating: "word ", count: 30)
        let title = PRBodyBuilder.title(long)
        #expect(title.count <= 72)
        #expect(title.hasSuffix("word"))
        #expect(!title.contains("\n"))
    }

    @Test func titleCutExactlyBeforeASpaceKeepsTheLastWord() {
        // 71 characters of words, then a space at index 72: the cut keeps the whole word.
        let text = String(repeating: "a", count: 71) + " tail"
        #expect(PRBodyBuilder.title(text) == String(repeating: "a", count: 71))
    }

    @Test func unbrokenLongTitleIsCutHard() {
        #expect(PRBodyBuilder.title(String(repeating: "x", count: 100)).count == 72)
    }

    @Test func multiLineTitleKeepsTheFirstLineOnly() {
        #expect(PRBodyBuilder.title("first line\nsecond   line") == "first line")
        #expect(PRBodyBuilder.title("  \n ") == "Workbench task")
    }

    @Test func eachCheckResultIsNamedAndOnlyPassedSaysPassed() {
        func line(_ r: String, exit: Int? = nil) -> String { PRBodyBuilder.checkLine(check(r, exit: exit)) }
        #expect(line("passed", exit: 0) == "Check: passed (exit 0, 12s)")
        #expect(line("failed", exit: 2) == "Check: failed (exit 2, 12s)")
        #expect(line("timed_out") == "Check: timed out (12s)")
        #expect(line("stopped", exit: 2) == "Check: stopped before it finished (exit 2, 12s)")
        #expect(line("interrupted") == "Check: interrupted, no result (12s)")
        #expect(PRBodyBuilder.checkLine(nil) == "Check: not run")
        for r in ["failed", "timed_out", "stopped", "interrupted", "weird"] {
            #expect(!line(r).contains("passed"))
        }
    }

    @Test func checkOutputIsNeverIncluded() {
        // The outcome carries a log reference only; nothing of the log can appear.
        let body = PRBodyBuilder.build(goal: goal(), check: check("failed", exit: 1), template: repoTemplate).body
        #expect(!body.contains("checks/turn-1.log"))
        #expect(body.contains("Check: failed (exit 1, 12s)"))
    }

    @Test func templateKeepsHeadingsInOrderAndFillsKnownOnes() {
        let g = goal(request: "Add retry.\n(Plan: docs/plan/P2.5-ship.md task 3)")
        let body = PRBodyBuilder.build(goal: g, check: check("passed"), template: repoTemplate).body
        let headings = body.split(separator: "\n").filter { $0.hasPrefix("## ") }
        #expect(headings == ["## Summary", "## Why", "## What changed", "## Testing"])
        #expect(body.contains("## Summary\n\nAdd retry."))
        #expect(body.contains("## Why\n\ndocs/plan/P2.5-ship.md task 3"))
        #expect(body.contains("## Testing\n\nCheck: passed (exit 0, 12s)"))
        #expect(body.contains("- [ ] Retries on 5xx, not 4xx."))
        // The template's own checklist is replaced by what Workbench knows, not left half true.
        #expect(!body.contains("scripts/check.sh` passes"))
    }

    @Test func unknownHeadingsKeepTheirTextAndCommentsAreDropped() {
        let template = """
            ## Summary
            <!-- hint -->
            ## Rollout
            Ship behind the flag.
            <!-- remove me -->
            ## Notes
            """
        let body = PRBodyBuilder.build(goal: goal(), check: nil, template: template).body
        #expect(body.contains("## Rollout\n\nShip behind the flag."))
        #expect(body.contains("## Notes"))
        #expect(!body.contains("<!--"))
        #expect(!body.contains("hint"))
    }

    @Test func templateWhyIsKeptWhenTheGoalNamesNoPlanTask() {
        let template = "## Why\n\nLinked issue: none\n"
        let body = PRBodyBuilder.build(goal: goal(), check: nil, template: template).body
        #expect(body.contains("Linked issue: none"))
    }

    @Test func headingInsideACodeFenceIsNotASection() {
        let template = "## Summary\n\n## Notes\n\n```\n## Testing\n```\n"
        let body = PRBodyBuilder.build(goal: goal(), check: check("passed"), template: template).body
        // The fenced line stays as it was; the real Testing section is appended after it.
        #expect(body.contains("```\n## Testing\n```\n\n## Testing\n\nCheck: passed"))
    }

    @Test func machinePathsAreRemoved() {
        let g = goal(
            request: "Edit /Users/gabriel/rogal/workbench/Sources/A.swift and see ~/notes/x.md.",
            criteria: [
                Criterion(
                    id: "c1", text: "Log at .workbench/threads/t1/events.jsonl is read",
                    proof: "run in /private/tmp/claude-501/x (see /var/folders/ab/cd)")
            ])
        let out = PRBodyBuilder.build(goal: g, check: nil, template: nil)
        for leak in ["/Users/", "gabriel", "~/notes", ".workbench/", "/private/", "/var/"] {
            #expect(!out.body.contains(leak), "leaked \(leak)")
        }
        #expect(out.body.contains("<path>"))
        #expect(PRBodyBuilder.scrub("see https://github.com/a/b/pull/1 and docs/spec/x.md") ==
            "see https://github.com/a/b/pull/1 and docs/spec/x.md")
    }

    @Test func urlAndPrefixedPathsAreRemoved() {
        let text = "see file:///Users/gabriel/p/x.swift and path:/Users/gabriel/p and (/Users/gabriel/p)"
        let out = PRBodyBuilder.scrub(text)
        #expect(!out.contains("gabriel"))
        #expect(PRBodyBuilder.scrub("https://example.com/Users/x") == "https://example.com/Users/x")
    }

    @Test func theWholePathGoesNotJustItsTail() {
        let out = PRBodyBuilder.scrub(
            "see /data/client/.workbench/worktrees/t1/A.swift and /Applications/client/A.swift and /tmp/x")
        #expect(out == "see <path> and <path> and <path>")
        #expect(PRBodyBuilder.scrub("[doc](https://github.com/a/b/blob/main/x.md)").contains("github.com/a/b/blob"))
    }

    @Test func indentedAndLongerFencesHideTheirHeadings() {
        let template = "## Notes\n\n   ```\n## Testing\n   ```\n\n````\n```\n## Summary\n```\n````\n"
        let body = PRBodyBuilder.build(goal: goal(), check: check("passed"), template: template).body
        #expect(body.contains("   ```\n## Testing\n   ```"))
        #expect(body.contains("````\n```\n## Summary\n```\n````"))
        // Nothing inside the fences was filled; the real sections were added around them.
        #expect(body.hasPrefix("## Summary\n\nAdd retry"))
        #expect(body.contains("\n\n## Testing\n\nCheck: passed"))
        #expect(body.components(separatedBy: "Check: passed").count == 2)
    }

    @Test func indentedCodeInAKeptSectionIsNotDedented() {
        let template = "## Rollout\n\n    run migrate\n"
        let body = PRBodyBuilder.build(goal: goal(), check: nil, template: template).body
        #expect(body.contains("## Rollout\n\n    run migrate"))
    }

    @Test func templateWithoutSummaryOrTestingStillCarriesRequestCriteriaAndCheck() {
        let body = PRBodyBuilder.build(
            goal: goal(), check: check("passed"), template: "## Rollout\n\nShip behind the flag.\n").body
        #expect(body.contains("## Summary\n\nAdd retry to `SyncClient.fetch`."))
        #expect(body.contains("- [ ] Delay is capped at 30s."))
        #expect(body.contains("Check: passed"))
        #expect(body.contains("## Rollout\n\nShip behind the flag."))
        let headings = body.split(separator: "\n").filter { $0.hasPrefix("## ") }
        #expect(headings == ["## Summary", "## Rollout", "## Testing"])
    }

    @Test func headingsWithClosingHashesAreRecognised() {
        let template = "## Summary ##\n\nhint\n\n## Testing ##\n\n- [ ] placeholder\n"
        let body = PRBodyBuilder.build(goal: goal(), check: check("passed"), template: template).body
        #expect(body.contains("## Summary ##\n\nAdd retry"))
        #expect(body.contains("## Testing ##\n\nCheck: passed"))
        #expect(!body.contains("placeholder") && !body.contains("hint"))
    }

    @Test func sameInputGivesTheSameOutput() {
        let a = PRBodyBuilder.build(goal: goal(), check: check("passed"), template: repoTemplate)
        let b = PRBodyBuilder.build(goal: goal(), check: check("passed"), template: repoTemplate)
        #expect(a == b)
    }

    @Test func repoTemplateFileProducesTheExpectedHeadings() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".github/pull_request_template.md")
        let text = try String(contentsOf: url, encoding: .utf8)
        let body = PRBodyBuilder.build(goal: goal(), check: check("passed"), template: text).body
        let headings = body.split(separator: "\n").filter { $0.hasPrefix("## ") }
        #expect(headings == ["## Summary", "## Why", "## What changed", "## Testing"])
        #expect(!body.contains("<!--"))
    }
}
