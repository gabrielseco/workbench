import Foundation
import Testing

@testable import WorkbenchCore

private func goal(request: String) -> Goal {
    Goal(
        id: "g1", title: "Add retry", declaredStatus: .approved, base: "main", budgetUSD: 5, turnTimeoutMin: 30,
        approvedAt: nil, approvedHash: nil, request: request, criteria: [], outOfScope: [], contentHash: "h")
}

private let template = """
    ## Summary

    <!-- What changes. -->

    ## Why

    <!-- The task or problem. -->

    ## What changed

    <details>
    <summary>Files and behaviour</summary>

    <!-- Per area, short. -->

    </details>

    ## Testing

    - [ ] checked
    """

private let described = PRDescription(title: "feat: retry", summary: "The model's words.", decisions: [], deviations: [])

private func change(
    _ path: String, _ added: Int, _ deleted: Int, from old: String? = nil, binary: Bool = false
) -> FileChange {
    FileChange(
        path: path, oldPath: old, status: old == nil ? .modified : .renamed, additions: binary ? nil : added,
        deletions: binary ? nil : deleted, isBinary: binary, isUntracked: false)
}

/// The text under `## <name>`, up to the next heading.
private func section(_ name: String, in body: String) -> String {
    let parts = body.components(separatedBy: "\n## ")
    let match = parts.first { $0.hasPrefix(name + "\n") || $0.hasPrefix("## " + name + "\n") }
    return (match ?? "").components(separatedBy: "\n").dropFirst().joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

@Suite struct PRBodySectionsTests {
    @Test func aPlanLineInTheRequestFillsWhyEvenWhenTheBodyIsDescribed() {
        let g = goal(request: "Add retry.\n(Plan: docs/plan/P2.5-ship.md task 3)")
        let body = PRBodyBuilder.build(goal: g, check: nil, template: template, description: described).body
        #expect(section("Why", in: body) == "docs/plan/P2.5-ship.md task 3", "\(body)")
        #expect(section("Summary", in: body).hasPrefix("The model's words."))
    }

    @Test func theModelsWhyComesFirstThenThePlanReference() {
        let said = PRDescription(
            title: "feat: retry", summary: "S.", why: "Fetch gave up on the first 5xx.", decisions: [], deviations: [])
        let g = goal(request: "Add retry.\n(Plan: docs/plan/P2.5-ship.md task 3)")
        let body = PRBodyBuilder.build(goal: g, check: nil, template: template, description: said).body
        #expect(
            section("Why", in: body) == "Fetch gave up on the first 5xx.\n\ndocs/plan/P2.5-ship.md task 3", "\(body)")
        let noPlan = PRBodyBuilder.build(goal: goal(request: "Add retry."), check: nil, template: template, description: said)
        #expect(section("Why", in: noPlan.body) == "Fetch gave up on the first 5xx.")
    }

    @Test func aDescribedBodyWithNoPlanLineUsesTheRequestsFirstParagraph() {
        let g = goal(request: "Add retry to fetch.\n\nSecond paragraph that stays out.")
        let body = PRBodyBuilder.build(goal: g, check: nil, template: template, description: described).body
        #expect(section("Why", in: body) == "Add retry to fetch.", "\(body)")
    }

    @Test func withNoDescriptionAndNoPlanLineWhyKeepsTheTemplate() {
        let g = goal(request: "Add retry to fetch.")
        let body = PRBodyBuilder.build(goal: g, check: nil, template: template).body
        #expect(section("Why", in: body) == "", "\(body)")
        #expect(section("Summary", in: body) == "Add retry to fetch.")
    }

    @Test func whatChangedListsFilesWithCountsRenamesAndBinaryFiles() {
        let changes = [
            change("Sources/A.swift", 10, 2), change("Docs/new.md", 3, 0, from: "Docs/old.md"),
            change("icon.png", 0, 0, binary: true),
        ]
        let body = PRBodyBuilder.build(
            goal: goal(request: "x"), check: nil, template: template, changes: changes
        ).body
        let text = section("What changed", in: body)
        #expect(text.contains("<summary>Files and behaviour (3 files  +13 −2)</summary>"), "\(text)")
        #expect(text.contains("- `Sources/A.swift`  +10 −2"), "\(text)")
        #expect(text.contains("- `Docs/old.md` → `Docs/new.md`  +3 −0"), "\(text)")
        #expect(text.contains("- `icon.png`  binary"), "\(text)")
        #expect(text.hasSuffix("</details>"))
    }

    @Test func whatChangedStopsAtFortyRows() {
        let changes = (1...45).map { change("f\($0).swift", 1, 0) }
        let text = PRBodyBuilder.changesSection(changes) ?? ""
        #expect(text.components(separatedBy: "\n").filter { $0.hasPrefix("- `f") }.count == 40)
        #expect(text.contains("- and 5 more files"))
    }

    @Test func noChangesLeavesTheTemplateSectionAlone() {
        #expect(PRBodyBuilder.changesSection([]) == nil)
        let body = PRBodyBuilder.build(goal: goal(request: "x"), check: nil, template: template).body
        #expect(section("What changed", in: body).contains("<summary>Files and behaviour</summary>"))
    }

    @Test func aTemplateWithoutThatHeadingGainsNothing() {
        let plain = "## Summary\n\n## Testing\n"
        let body = PRBodyBuilder.build(
            goal: goal(request: "x"), check: nil, template: plain, changes: [change("a.swift", 1, 1)]
        ).body
        #expect(!body.contains("What changed"), "\(body)")
    }
}
