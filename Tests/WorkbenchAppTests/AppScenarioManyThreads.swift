import Foundation

extension AppScenario {
    /// The rail's ten and Show more: fourteen finished threads (accepted, abandoned, discarded), and the oldest of all one that needs you,
    /// which the limit never hides.
    @MainActor func buildManyThreads(in fixture: AppFixture) async throws {
        try await fixture.addThread("a-old-review", approved: true, title: "Review the contract version bump")
        try fixture.append("a-old-review", .turnStarted, turn: 1, data: ["session_id": "s1"])
        try fixture.append("a-old-review", .turnEnded, turn: 1, data: ["result": "succeeded", "cost_usd": 0.8])
        try fixture.append("a-old-review", .checkStarted, turn: 1)
        try fixture.append(
            "a-old-review", .checkRan, turn: 1, data: ["result": "passed", "tests_passed": ["a"], "tests_failed": []])
        let decisions = ["accepted", "abandoned", "discarded"]
        for index in 1...14 {
            let id = String(format: "t%02d-finished", index)
            try await fixture.addThread(id, approved: true, title: "Finished thread number \(index)")
            try fixture.turn(id, 1, cost: 0.5)
            try fixture.decide(id, decisions[index % decisions.count])
        }
    }
}
