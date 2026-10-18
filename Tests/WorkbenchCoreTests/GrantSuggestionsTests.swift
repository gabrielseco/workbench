import Foundation
import Testing

@testable import WorkbenchCore

private let tools = ToolSet(available: ["Read", "Bash"], allowed: ["Read", "Bash(swift build:*)"], denied: ["Bash(git push:*)"])

/// A thread whose one finished turn was denied these commands, then optionally decided about some.
private func thread(
    _ id: String, denied commands: [String], decisions: [(String, String)] = []
) -> (id: String, events: [Event]) {
    var events: [Event] = []
    func add(_ kind: EventKind, _ turn: Int, _ data: JSONValue) {
        events.append(Event(seq: events.count + 1, ts: "2026-10-18T10:00:00.000Z", turn: turn, kind: kind, data: data))
    }
    add(.turnStarted, 1, ["session_id": "s", "resume": false])
    add(.claude, 1, ["type": "result", "permission_denials": .array(commands.map(bashDenial))])
    add(.turnEnded, 1, ["result": "succeeded", "permission_denials": .int(commands.count)])
    for (scope, pattern) in decisions {
        add(.grantAdded, 0, ["scope": .string(scope), "pattern": .string(pattern)])
    }
    return (id, events)
}

@Suite struct GrantSuggestionsTests {
    @Test func aSafePrefixDeniedInTwoThreadsIsSuggestedWithTheThreadsItHappenedIn() {
        let found = GrantSuggestions.derive(
            threads: [
                thread("a", denied: ["git show HEAD"]), thread("b", denied: ["git show HEAD~1", "ls"]),
                thread("c", denied: ["git log"]),
            ], tools: tools)
        #expect(found == [GrantSuggestion(pattern: "Bash(git show:*)", threads: ["a", "b"])])
        #expect(found[0].configEntry == "\"Bash(git show:*)\"")
    }

    @Test func oneThreadIsNotARepeatAndNeitherIsTheSameCommandTwiceInIt() {
        let one = thread("a", denied: ["git show HEAD", "git show HEAD~1"])
        #expect(GrantSuggestions.derive(threads: [one], tools: tools).isEmpty)
    }

    @Test func onlySafeNarrowPrefixesAreEverSuggested() {
        let commands = ["git push origin x", "rm -rf build", "python3 x.py", "mkdir -p scratch", "ln -s a b", "git stash"]
        let threads = ["a", "b", "c"].map { thread($0, denied: commands) }
        #expect(GrantSuggestions.derive(threads: threads, tools: tools).isEmpty)
    }

    @Test func whatTheProjectAlreadyAllowsOrDeniesIsNotSuggested() {
        let threads = ["a", "b"].map { thread($0, denied: ["swift build", "git diff", "git push origin x"]) }
        let found = GrantSuggestions.derive(threads: threads, tools: tools)
        #expect(found.map(\.pattern) == ["Bash(git diff:*)"])
        let everything = ToolSet(available: ["Bash"], allowed: ["Bash"], denied: [])
        #expect(GrantSuggestions.derive(threads: threads, tools: everything).isEmpty)
    }

    @Test func aPatternTurnedDownInAnyThreadIsNotSuggested() {
        let threads = [
            thread("a", denied: ["git show HEAD"]), thread("b", denied: ["git show HEAD"]),
            thread("c", denied: ["git show HEAD"], decisions: [("never", "Bash(git show:*)")]),
        ]
        #expect(GrantSuggestions.derive(threads: threads, tools: tools).isEmpty)
    }

    @Test func theMostRepeatedComesFirstAndEachPartOfACompoundCounts() {
        let threads = [
            thread("a", denied: ["git show HEAD && git log -1"]), thread("b", denied: ["git log"]),
            thread("c", denied: ["git show x; git log"]),
        ]
        let found = GrantSuggestions.derive(threads: threads, tools: tools)
        #expect(found.map(\.pattern) == ["Bash(git log:*)", "Bash(git show:*)"])
        #expect(found.map { $0.threads.count } == [3, 2])
    }

    @Test func noThreadsNoSuggestions() {
        #expect(GrantSuggestions.derive(threads: [], tools: tools).isEmpty)
        #expect(GrantReport.renderSuggestions([]).isEmpty)
    }
}

@Suite struct GrantSuggestionsCLITests {
    private func cli(_ arguments: [String], in fx: RunnerFixture) async throws -> (text: String, exit: ProcessExit?) {
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
        return (lines.joined(separator: "\n"), exit)
    }

    private func twoThreads(_ fx: RunnerFixture, secondDenies: String) async throws -> (first: String, second: String) {
        let first = try await fx.approvedThread("first")
        try await denyInLog(fx, first, ["git show HEAD"])
        let log = try EventLogWriter.open(at: fx.project.eventsURL(first))
        _ = try await log.append(.reviewDecision, data: ["decision": "abandoned", "by": "user"])
        await log.close()
        let second = try await fx.approvedThread("second")
        try await denyInLog(fx, second, [secondDenies])
        return (first, second)
    }

    @Test func theListAndADecisionSuggestTheConfigLineAndChangeNothing() async throws {
        let fx = try await RunnerFixture()
        _ = try await twoThreads(fx, secondDenies: "git show HEAD~1")
        let before = try String(contentsOf: fx.project.configURL, encoding: .utf8)

        let list = try await cli(["grant"], in: fx)
        #expect(list.text.contains("Denied in more than one thread and safe"), "\(list.text)")
        #expect(list.text.contains("\"Bash(git show:*)\",   (2 threads)"), "\(list.text)")

        let decided = try await cli(["grant", "1", "--thread"], in: fx)
        #expect(decided.exit?.termination == .exited(0), "\(decided.text)")
        #expect(decided.text.contains("\"Bash(git show:*)\",   (2 threads)"), "\(decided.text)")
        #expect(try String(contentsOf: fx.project.configURL, encoding: .utf8) == before)

        let json = try await cli(["grant", "--json"], in: fx)
        let parsed = try JSONDecoder().decode(JSONValue.self, from: Data(json.text.utf8))
        guard case .array(let suggestions)? = parsed["suggestions"], let first = suggestions.first else {
            Issue.record("\(json.text)")
            return
        }
        #expect(
            first["pattern"]?.stringValue == "Bash(git show:*)" && first["config_entry"]?.stringValue == "\"Bash(git show:*)\"")
    }

    @Test func nothingRepeatedMeansNothingSaid() async throws {
        let fx = try await RunnerFixture()
        _ = try await twoThreads(fx, secondDenies: "git log -1")
        let list = try await cli(["grant"], in: fx)
        #expect(!list.text.contains("more than one thread"), "\(list.text)")
        let decided = try await cli(["grant", "1", "--once"], in: fx)
        #expect(!decided.text.contains("more than one thread"), "\(decided.text)")
    }

    @Test func aDecisionToTurnItDownSuggestsNothing() async throws {
        let fx = try await RunnerFixture()
        _ = try await twoThreads(fx, secondDenies: "git show HEAD~1")
        let never = try await cli(["grant", "1", "--never"], in: fx)
        #expect(!never.text.contains("more than one thread"), "\(never.text)")
        let list = try await cli(["grant"], in: fx)
        #expect(!list.text.contains("more than one thread"), "\(list.text)")
    }
}
