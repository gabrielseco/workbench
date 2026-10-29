import Foundation
import WorkbenchCore

@testable import WorkbenchApp

/// The fixture projects `scripts/verify-app.sh` shows the app: one per state, committed under `Fixtures/app/<name>/threads/` (not
/// `.workbench/`, which `.gitignore` ignores). This is the one place that writes them, so a change to the log format is a change here,
/// and `FixtureScenarioTests` fails when a committed file differs from what this writes. To rewrite them:
///   WORKBENCH_WRITE_FIXTURES=Fixtures/app swift test --filter FixtureScenarioTests/writeTheScenarios
enum AppScenario: String, CaseIterable {
    case draft
    case goalWarning = "goal-warning"
    case goalApproved = "goal-approved"
    case running
    case needsYou = "needs-you"
    case accepted
    case prOpen = "pr-open"
    case cleaned
    case discarded
    case corrupt
    case noThread = "no-thread"
    case draftGoal = "draft-goal"

    private static let title = "Paginate the contractor invoice list"

    /// The config a scenario ships, for the ones that show how proofs are judged against the tool set.
    var config: String? {
        switch self {
        case .goalWarning:
            "[tools]\navailable = [\"Read\", \"Bash\"]\nallowed = [\"Read\", \"Bash(swift test:*)\"]\n"
        case .goalApproved:
            // Shows the screen's "Also reads" line: the folder is only named on screen, nothing opens it.
            "read_also = [\"../expenses-backend\"]\n\n"
                + "[tools]\navailable = [\"Read\", \"Bash\"]\nallowed = [\"Read\", \"Bash(swift test:*)\"]\n"
        case .draftGoal:
            // The goal agent is the real Codex: this is the scenario that drafts a goal for real, from a request and screenshots.
            "[tools]\navailable = [\"Read\"]\nallowed = [\"Read\"]\n\n[agents.goal]\nprovider = \"codex\"\n"
        default: nil
        }
    }

    /// Writes this scenario's thread(s) into a fresh fixture, as the real files.
    @MainActor func build(in fixture: AppFixture) async throws {
        let id = "invoice-pagination"
        switch self {
        case .draft:
            try await fixture.addThread(id, title: Self.title)
        case .goalWarning:
            // The fixture repository has no commit, so no verifier skill is at the base: the screenshot proof cannot be made.
            try await fixture.addThread(
                id, title: Self.title,
                proofs: ["`swift test` passes", "`./scripts/deploy.sh` exits 0", "screenshot: invoice-list"])
        case .goalApproved:
            try await fixture.addThread(id, approved: true, title: Self.title, proofs: ["`swift test` passes"])
        case .running:
            try await fixture.addThread(id, approved: true, title: Self.title)
            try fixture.append(id, .turnStarted, turn: 1, data: ["session_id": "s1"])
            try fixture.activity(id, ["type": "text", "text": "Reading the invoice list and its tests"])
            try fixture.activity(id, ["type": "tool", "name": "Read", "summary": "Sources/Invoices/List.swift"])
            try fixture.activity(id, ["type": "tool", "name": "Edit", "summary": "Sources/Invoices/List.swift"])
            try fixture.activity(id, ["type": "permission_denied", "tool": "Bash"])
        case .needsYou:
            try await fixture.addThread(id, approved: true, title: Self.title)
            try fixture.append(id, .turnStarted, turn: 1, data: ["session_id": "s1"])
            try fixture.activity(id, ["type": "tool", "name": "Edit", "summary": "Sources/Invoices/List.swift"])
            try fixture.activity(id, ["type": "tool", "name": "Write", "summary": "Tests/InvoiceListTests.swift"])
            try fixture.activity(id, ["type": "permission_denied", "tool": "Bash"])
            let denial: JSONValue = [["tool": "Bash", "input": "git push origin main"]]
            try fixture.append(
                id, .turnEnded, turn: 1,
                data: ["result": "succeeded", "cost_usd": 1.88, "permission_denials": 1, "denials": denial])
            try fixture.append(id, .checkStarted, turn: 1)
            try fixture.append(
                id, .checkRan, turn: 1, data: ["result": "passed", "tests_passed": ["a", "b", "c"], "tests_failed": []])
        case .accepted:
            try await fixture.addThread(id, approved: true, title: Self.title)
            try fixture.turn(id, 1, cost: 1.88)
            try fixture.decide(id, "accepted")
        case .prOpen:
            try await fixture.addThread(id, approved: true, title: Self.title)
            try fixture.turn(id, 1, cost: 1.88)
            try fixture.decide(id, "accepted")
            try fixture.ship(id, number: 482)
        case .cleaned:
            try await fixture.addThread(id, approved: true, title: Self.title)
            try fixture.turn(id, 1, cost: nil)
            try fixture.decide(id, "accepted")
            try fixture.ship(id, number: 482)
            try fixture.append(id, .branchRemoved, data: ["reason": "merged"])
        case .discarded:
            try await fixture.addThread(id, approved: true, title: Self.title)
            try fixture.append(id, .turnStarted, turn: 1, data: ["session_id": "s1", "provider": "codex"])
            try fixture.append(
                id, .agentActivity, turn: 1,
                data: ["provider": "codex", "type": "text", "text": "I'll check how the page handles the dialog"])
            try fixture.append(
                id, .agentActivity, turn: 1,
                data: ["provider": "codex", "type": "tool", "name": "shell", "summary": "git status --short"])
            try fixture.append(
                id, .turnEnded, turn: 1, data: ["result": "succeeded"], ts: "2026-10-28T11:04:12.000Z")
            try fixture.decide(id, "discarded")
        case .corrupt:
            try await fixture.addThread(id, approved: true, title: Self.title)
            try fixture.overwriteLog(id, with: "not json\n{broken\n")
        case .noThread, .draftGoal:
            break
        }
    }

    /// Writes every scenario under `directory/<name>/`: its threads folder, or a `.gitkeep` for the one with none.
    @MainActor static func writeAll(into directory: URL) async throws {
        let files = FileManager.default
        for scenario in allCases {
            let fixture = try await AppFixture(git: false)
            try await scenario.build(in: fixture)
            let target = directory.appendingPathComponent(scenario.rawValue)
            try? files.removeItem(at: target)
            try files.createDirectory(at: target, withIntermediateDirectories: true)
            if let config = scenario.config {
                try config.write(to: target.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
            }
            let threads = fixture.project.threadsDirectory
            if (try? files.contentsOfDirectory(atPath: threads.path))?.isEmpty == false {
                try files.copyItem(at: threads, to: target.appendingPathComponent("threads"))
            } else {
                try Data().write(to: target.appendingPathComponent(".gitkeep"))
            }
        }
    }
}
