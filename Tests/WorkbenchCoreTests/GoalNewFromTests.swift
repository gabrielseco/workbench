import Foundation
import Testing

@testable import WorkbenchCore

private func cli(_ arguments: [String], in fx: RunnerFixture) async throws -> (code: Int32?, text: String) {
    var spawn = SpawnRequest(
        executable: WorkbenchBinary.executable, arguments: arguments,
        environment: ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "USER": NSUserName()],
        workingDirectory: fx.repo, timeout: 60)
    spawn.snapshotInterval = 3600
    let run = try ProcessRunner.start(spawn)
    var lines: [String] = []
    var exit: ProcessExit?
    for await event in run.events {
        if case .line(let line) = event { lines.append(line) }
        if case .exited(let e) = event { exit = e }
    }
    var code: Int32?
    if case .exited(let c)? = exit?.termination { code = c }
    return (code, (lines + [exit?.stderrTail ?? ""]).joined(separator: "\n"))
}

private func source(budget: String = "8", extra: String = "") -> String {
    """
    ---
    id: g-2026-01-01-source
    title: Source
    status: approved
    base: release
    budget_usd: \(budget)
    turn_timeout_min: 30\(extra)
    ---

    ## Request

    Make it work.

    ## Criteria

    - [c1] It works.
      - proof: swift test
    """
}

private func write(_ text: String, in fx: RunnerFixture) throws -> String {
    let url = fx.repo.appendingPathComponent("source.md")
    try text.write(to: url, atomically: true, encoding: .utf8)
    return url.path
}

@Suite struct GoalNewFromTests {
    @Test func theFileBudgetReachesTheDraftAndTheIgnoredKeysAreNamed() async throws {
        let fx = try await RunnerFixture()
        let result = try await cli(["goal", "new", "copy", "--from", try write(source(), in: fx)], in: fx)
        #expect(result.code == 0, "\(result.text)")
        #expect(result.text.contains("ignored from the file: id, title, status, base"))
        let id = try #require(ThreadStore(project: fx.project).threadIDs().first)
        let goal = try GoalFile.parse(String(contentsOf: fx.project.goalURL(id), encoding: .utf8)).goal
        #expect(goal.budgetUSD == 8)
        #expect(goal.base == "main")
        #expect(goal.approval == .draft)
    }

    @Test func aBadBudgetIsAUsageErrorAndCreatesNothing() async throws {
        let fx = try await RunnerFixture()
        let result = try await cli(["goal", "new", "copy", "--from", try write(source(budget: "lots"), in: fx)], in: fx)
        #expect(result.code == 2, "\(result.text)")
        #expect(result.text.contains("workbench: usage:"))
        #expect(result.text.contains("'budget_usd'"))
        #expect(ThreadStore(project: fx.project).threadIDs().isEmpty)
    }

    @Test func nothingIsNamedWhenNothingIsIgnored() async throws {
        let fx = try await RunnerFixture()
        let text =
            "---\nbudget_usd: 3\n---\n\n## Request\n\nMake it work.\n\n## Criteria\n\n- [c1] It works.\n  - proof: swift test\n"
        let result = try await cli(["goal", "new", "copy", "--from", try write(text, in: fx)], in: fx)
        #expect(result.code == 0, "\(result.text)")
        #expect(!result.text.contains("ignored from the file"))
    }
}
