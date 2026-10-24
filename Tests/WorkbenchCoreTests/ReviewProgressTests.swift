import Foundation
import Testing

@testable import WorkbenchCore

/// The line printed before a review names the agent `[agents.review]` (or the stage) chose, not always Codex.
@Suite struct ReviewProgressTests {
    private static let tools = "\n[tools]\navailable = [\"Read\"]\nallowed = [\"Read\"]\n"
    private static let wait = "(read-only; this can take several minutes)..."

    private func parse(_ text: String) throws -> Config { try Config.parse(text + Self.tools) }

    @Test func codexByDefault() throws {
        let config = try parse("")
        #expect(ReviewProgress.pullRequest(7, config: config) == "asking Codex to review pull request #7 \(Self.wait)")
        #expect(
            ReviewProgress.stage("pr-review", thread: "t1", config: config)
                == "asking Codex to review the pull request of t1 \(Self.wait)")
        #expect(ReviewProgress.loopRound(config: config) == "asking Codex to review the pull request \(Self.wait)")
    }

    @Test func claudeWhenConfigured() throws {
        let config = try parse("[agents.review]\nprovider = \"claude\"\nallow_unpriced = true")
        #expect(ReviewProgress.pullRequest(7, config: config) == "asking Claude to review pull request #7 \(Self.wait)")
        #expect(
            ReviewProgress.stage("pr-review", thread: "t1", config: config)
                == "asking Claude to review the pull request of t1 \(Self.wait)")
        #expect(ReviewProgress.loopRound(config: config) == "asking Claude to review the pull request \(Self.wait)")
    }

    @Test func aStageNamesItsOwnAgent() throws {
        let config = try parse(
            """
            [agents.review]
            provider = "claude"
            [review]
            stages = ["pr-review", "design", "plain"]
            [review.stage.design]
            provider = "codex"
            prompt = "docs/D.md"
            [review.stage.plain]
            prompt = "docs/P.md"
            """)
        #expect(
            ReviewProgress.stage("design", thread: "t1", config: config)
                == "asking Codex to review the pull request of t1 as the design stage \(Self.wait)")
        #expect(
            ReviewProgress.stage("plain", thread: "t1", config: config)
                == "asking Claude to review the pull request of t1 as the plain stage \(Self.wait)")
    }
}
