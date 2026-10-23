import Foundation
import Testing

@testable import WorkbenchCore

private let tools = ToolSet(
    available: ["Read", "Edit", "Bash"], allowed: ["Read", "Edit", "Bash(git status:*)"],
    denied: ["Bash(git push:*)"])

private func events(_ items: [(EventKind, JSONValue)]) -> [Event] {
    items.enumerated().map { index, item in
        Event(seq: index + 1, ts: "2026-10-18T10:00:00.000Z", turn: 0, kind: item.0, data: item.1)
    }
}

private func grant(_ scope: String, _ pattern: String) -> (EventKind, JSONValue) {
    (.grantAdded, ["scope": .string(scope), "pattern": .string(pattern)])
}

private let turnStarted: (EventKind, JSONValue) = (.turnStarted, [:])

@Suite(.processGate) struct GrantLedgerTests {
    @Test func aThreadGrantAppliesToEveryLaterTurn() {
        let ledger = GrantLedger(events: events([grant("thread", "Bash(chmod +x scripts/a.sh)"), turnStarted, turnStarted]))
        #expect(ledger.patternsForNextTurn(tools: tools) == ["Bash(chmod +x scripts/a.sh)"])
    }

    @Test func aOnceGrantIsForTheNextTurnOnly() {
        let before = GrantLedger(events: events([turnStarted, grant("once", "Bash(ln -s a b)")]))
        #expect(before.patternsForNextTurn(tools: tools) == ["Bash(ln -s a b)"])
        let spent = GrantLedger(events: events([turnStarted, grant("once", "Bash(ln -s a b)"), turnStarted]))
        #expect(spent.patternsForNextTurn(tools: tools).isEmpty)
    }

    @Test func aNeverRecordAllowsNothingAndIsListedAsRefused() {
        let ledger = GrantLedger(events: events([grant("never", "Bash(rm x)")]))
        #expect(ledger.patternsForNextTurn(tools: tools).isEmpty)
        #expect(ledger.refused == ["Bash(rm x)"])
    }

    @Test func theLatestWordOnAPatternStands() {
        let granted = events([grant("thread", "Bash(ls)"), grant("never", "Bash(ls)")])
        #expect(GrantLedger(events: granted).patternsForNextTurn(tools: tools).isEmpty)
        #expect(GrantLedger(events: granted).refused == ["Bash(ls)"])
        let onceRevoked = events([grant("once", "Bash(ls)"), grant("never", "Bash(ls)")])
        #expect(GrantLedger(events: onceRevoked).patternsForNextTurn(tools: tools).isEmpty)
        let changedMind = events([grant("never", "Bash(ls)"), grant("thread", "Bash(ls)")])
        #expect(GrantLedger(events: changedMind).patternsForNextTurn(tools: tools) == ["Bash(ls)"])
        #expect(GrantLedger(events: changedMind).refused.isEmpty)
        let spentOnceKeepsThread = events([grant("thread", "Bash(ls)"), turnStarted, grant("once", "Bash(ls)"), turnStarted])
        #expect(GrantLedger(events: spentOnceKeepsThread).patternsForNextTurn(tools: tools) == ["Bash(ls)"])
    }

    @Test func aGrantTheProjectDeniesOrAlreadyAllowsIsLeftOut() {
        let ledger = GrantLedger(
            events: events([
                grant("thread", "Bash(git push:*)"), grant("thread", "Bash(git status:*)"),
                grant("thread", "Bash(ls)"), grant("once", "Bash(ls)"),
            ]))
        #expect(ledger.patternsForNextTurn(tools: tools) == ["Bash(ls)"])
    }

    @Test func aPatternThatWouldAllowEverythingOrNamesNoToolOfTheProjectIsIgnored() {
        let bad = [
            "Bash", "Bash(*)", "Bash(:*)", "Bash( )", "Bash(*:*)", "Write(notes.md)", "Bash(ls)\nBash", "(ls)", "Ba sh(ls)",
            "Bash(ls", "", String(repeating: "x", count: 2001),
        ]
        let ledger = GrantLedger(events: events(bad.map { grant("thread", $0) }))
        #expect(ledger.patternsForNextTurn(tools: tools).isEmpty)
        for pattern in bad { #expect(GrantPattern.problem(pattern, available: tools.available) != nil, "\(pattern)") }
        #expect(GrantPattern.problem("Bash(gh pr view:*)", available: tools.available) == nil)
        #expect(GrantPattern.problem("Edit(docs/a.md)", available: tools.available) == nil)
    }

    @Test func damagedGrantEventsAreSkipped() {
        let ledger = GrantLedger(
            events: events([
                (.grantAdded, ["scope": "sometimes", "pattern": "Bash(ls)"]), (.grantAdded, ["scope": "thread"]),
                (.grantAdded, ["pattern": "Bash(ls)"]), (.grantAdded, .null), grant("thread", "Bash(pwd)"),
            ]))
        #expect(ledger.records.map(\.pattern) == ["Bash(pwd)"])
    }

    @Test func theGrantsReachAllowedToolsButNeverAddDeniedOnes() throws {
        let config = try Config.parse(
            "[tools]\navailable = [\"Read\", \"Bash\"]\nallowed = [\"Read\"]\ndenied = [\"Bash(git push:*)\"]")
        let turn = TurnRequest(
            sessionID: UUID(), resume: false, budgetUSD: 1, prompt: "x",
            extraAllowed: ["Bash(chmod +x a.sh)", "Read", "Bash(git push:*)", "Bash(chmod +x a.sh)"])
        let args = try config.invocation(for: turn).arguments
        let allowed = args.firstIndex(of: "--allowedTools").map { Array(args[($0 + 1)...].prefix { !$0.hasPrefix("--") }) }
        #expect(allowed == ["Read", "Bash(chmod +x a.sh)"])
        let denied = args.firstIndex(of: "--disallowedTools").map { Array(args[($0 + 1)...].prefix { !$0.hasPrefix("--") }) }
        #expect(denied == ["Bash(git push:*)"])
    }
}

@Suite(.processGate) struct GrantRunnerTests {
    private func argv(_ fx: RunnerFixture, _ id: String, turn: Int) throws -> [String] {
        let started = try #require(try fx.events(id).first { $0.kind == .turnStarted && $0.turn == turn })
        guard case .array(let items)? = started.data["argv"] else { return [] }
        return items.compactMap(\.stringValue)
    }

    private func allowedIn(_ args: [String]) -> [String] {
        args.firstIndex(of: "--allowedTools").map { Array(args[($0 + 1)...].prefix { !$0.hasPrefix("--") }) } ?? []
    }

    @Test func aGrantReachesTheNextTurnAndAOnceGrantIsSpentByIt() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        let log = try EventLogWriter.open(at: fx.project.eventsURL(id))
        _ = try await log.append(.grantAdded, data: ["scope": "once", "pattern": "Bash(chmod +x scripts/a.sh)"])
        _ = try await log.append(.grantAdded, data: ["scope": "thread", "pattern": "Bash(ln -s a b)"])
        await log.close()

        _ = try await fx.runner(id).run(fx.options())
        _ = try await fx.runner(id).run(fx.options(feedback: "again"))

        let first = allowedIn(try argv(fx, id, turn: 1))
        #expect(first.contains("Bash(chmod +x scripts/a.sh)") && first.contains("Bash(ln -s a b)"), "\(first)")
        let second = allowedIn(try argv(fx, id, turn: 2))
        #expect(!second.contains("Bash(chmod +x scripts/a.sh)"), "\(second)")
        #expect(second.contains("Bash(ln -s a b)"))
    }

    @Test func aThreadWithoutGrantsRunsWithTheProjectsToolsExactly() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        _ = try await fx.runner(id).run(fx.options())
        #expect(allowedIn(try argv(fx, id, turn: 1)) == ["Read", "Edit"])
    }
}
