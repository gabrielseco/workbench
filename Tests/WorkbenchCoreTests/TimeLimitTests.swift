import Foundation
import Testing

@testable import WorkbenchCore

private let goalText = """
    ---
    id: g-2026-10-12-retry-backoff
    title: Add retry
    status: draft
    base: main
    budget_usd: 5.00
    turn_timeout_min: 30
    ---

    ## Request

    Add retry.

    ## Criteria

    - [c1] It retries.
      - proof: test `RetryTests` pass

    ## Out of scope

    - Nothing.
    """

struct TimeLimitTests {
    @Test func minutesAreCountedInSeconds() {
        #expect(TimeInterval.minutes(1) == 60)
        #expect(TimeInterval.minutes(30) == 1800)
        #expect(TimeInterval.minutes(0) == 0)
    }

    @Test func aGoalsTurnTimeoutIsItsMinutesInSeconds() throws {
        let goal = try GoalFile.parse(goalText).goal
        #expect(goal.turnTimeoutMin == 30)
        #expect(goal.turnTimeout == 1800)
    }

    @Test func aVerifiersTimeoutIsItsMinutesInSeconds() {
        #expect(VerifierConfig(timeoutMin: 10).timeout == 600)
        #expect(VerifierConfig().timeout == TimeInterval(VerifierConfig.defaultTimeoutMin) * 60)
    }
}
