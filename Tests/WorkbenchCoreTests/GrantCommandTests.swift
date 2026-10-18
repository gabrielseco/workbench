import Foundation
import Testing

@testable import WorkbenchCore

private func denial(_ command: String) -> JSONValue {
    ["tool_name": "Bash", "tool_use_id": "toolu_1", "tool_input": ["command": .string(command)]]
}

/// A finished turn in the thread's log whose result line lists these denials; returns the `claude` line's seq.
@discardableResult
private func denyInLog(_ fx: RunnerFixture, _ id: String, _ commands: [String]) async throws -> Int {
    let log = try EventLogWriter.open(at: fx.project.eventsURL(id))
    let turn = await log.lastTurn + 1
    _ = try await log.append(.turnStarted, turn: turn, data: ["session_id": "s", "resume": false])
    let line = try await log.append(
        .claude, turn: turn,
        data: ["type": "result", "permission_denials": .array(commands.map(denial))])
    _ = try await log.append(
        .turnEnded, turn: turn, data: ["result": "succeeded", "permission_denials": .int(commands.count)])
    await log.close()
    return line.seq
}

private func grantEvents(_ fx: RunnerFixture, _ id: String) throws -> [Event] {
    try fx.events(id).filter { $0.kind == .grantAdded }
}

@Suite struct GrantCommandTests {
    @Test func denialsAreNumberedInTheOrderTheyFirstHappenedAndGroupedByWholeInput() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        try await denyInLog(fx, id, ["git push origin main", "chmod +x a.sh && ls", "git push origin main"])
        try await denyInLog(fx, id, ["chmod +x a.sh && ls", "ln -s a b"])
        let found = try fx.service.grantCandidates(id: id)
        #expect(found.map(\.number) == [1, 2, 3])
        #expect(found.map(\.input) == ["git push origin main", "chmod +x a.sh && ls", "ln -s a b"])
        #expect(found[1].turns == [1, 2] && found[1].assessment.isCompound)
        #expect(found[1].parts.map(\.number) == ["2.1", "2.2"])
        #expect(found[0].assessment.level == .unsafe)
    }

    @Test func aGrantIsRecordedInTheLogAndReachesTheNextRun() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        let seq = try await denyInLog(fx, id, ["chmod +x scripts/x.sh"])
        let outcome = try await fx.service.grant(id: id, target: "1", scope: .thread)
        #expect(outcome.pattern == "Bash(chmod +x scripts/x.sh)" && outcome.seq != nil)

        let events = try grantEvents(fx, id)
        #expect(events.count == 1)
        #expect(events[0].data["pattern"]?.stringValue == "Bash(chmod +x scripts/x.sh)")
        #expect(events[0].data["scope"]?.stringValue == "thread")
        #expect(events[0].data["denial_seq"]?.intValue == seq)
        #expect(events[0].data["level"]?.stringValue == "safe")
        #expect(try fx.service.grantCandidates(id: id)[0].status == .granted(.thread))

        _ = try await fx.runner(id).run(fx.options(feedback: "go on"))
        let started = try #require(try fx.events(id).last { $0.kind == .turnStarted })
        guard case .array(let argv)? = started.data["argv"] else {
            Issue.record("no argv")
            return
        }
        #expect(argv.compactMap(\.stringValue).contains("Bash(chmod +x scripts/x.sh)"))
        let config = try String(contentsOf: fx.project.configURL, encoding: .utf8)
        #expect(!config.contains("chmod"), "a grant is never written to the config")
    }

    @Test func aCompoundIsNeverGrantedWholeButItsPartsAre() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        try await denyInLog(fx, id, ["chmod +x a.sh && bash -n a.sh"])
        await #expect(throws: GrantError.self) { try await fx.service.grant(id: id, target: "1", scope: .thread) }
        await #expect(throws: GrantError.self) { try await fx.service.grant(id: id, target: "1", scope: .once) }
        #expect(try grantEvents(fx, id).isEmpty)
        let part = try await fx.service.grant(id: id, target: "1.1", scope: .once)
        #expect(part.pattern == "Bash(chmod +x a.sh)")
        let never = try await fx.service.grant(id: id, target: "1", scope: .never)
        #expect(never.pattern == "Bash(chmod +x a.sh && bash -n a.sh)")
        #expect(try fx.service.grantCandidates(id: id)[0].status == .refused)
    }

    @Test func unsafeNeedsAFlagAndIsOnlyEverOnce() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        try await denyInLog(fx, id, ["rm -rf build"])
        for scope in [GrantScope.once, .thread] {
            await #expect(throws: GrantError.self) { try await fx.service.grant(id: id, target: "1", scope: scope) }
        }
        await #expect(throws: GrantError.self) {
            try await fx.service.grant(id: id, target: "1", scope: .thread, allowDangerous: true)
        }
        #expect(try grantEvents(fx, id).isEmpty)
        let once = try await fx.service.grant(id: id, target: "1", scope: .once, allowDangerous: true)
        #expect(once.level == .unsafe && once.seq != nil)
    }

    @Test func whatCannotBeWrittenAsAFixedPatternIsRefusedButCanBeTurnedDown() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        try await denyInLog(fx, id, ["cat > f.sh <<'EOF'\necho hi\nEOF"])
        await #expect(throws: GrantError.self) { try await fx.service.grant(id: id, target: "1", scope: .thread) }
        _ = try await fx.service.grant(id: id, target: "1", scope: .never)
        #expect(try fx.service.grantCandidates(id: id)[0].status == .refused)
    }

    @Test func theProjectsDeniedListStillWins() async throws {
        let fx = try await RunnerFixture()
        let config = try String(contentsOf: fx.project.configURL, encoding: .utf8)
        try config.replacingOccurrences(
            of: "allowed = [\"Read\", \"Edit\"]", with: "allowed = [\"Read\", \"Edit\"]\ndenied = [\"Bash(git push:*)\"]"
        ).write(to: fx.project.configURL, atomically: true, encoding: .utf8)
        let id = try await fx.approvedThread()
        try await denyInLog(fx, id, ["git push origin workbench/x"])
        let error = await #expect(throws: GrantError.self) {
            try await fx.service.grant(id: id, target: "1", scope: .once, allowDangerous: true)
        }
        #expect("\(String(describing: error))".contains("denied"))
        #expect(try grantEvents(fx, id).isEmpty)
    }

    @Test func turningAGrantedCommandDownTakesItBackFromTheNextRun() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        try await denyInLog(fx, id, ["ls docs"])
        _ = try await fx.service.grant(id: id, target: "1", scope: .thread)
        _ = try await fx.service.grant(id: id, target: "1", scope: .never)
        #expect(try fx.service.grantCandidates(id: id)[0].status == .refused)
        _ = try await fx.runner(id).run(fx.options(feedback: "go on"))
        let started = try #require(try fx.events(id).last { $0.kind == .turnStarted })
        guard case .array(let argv)? = started.data["argv"] else {
            Issue.record("no argv")
            return
        }
        #expect(!argv.compactMap(\.stringValue).contains("Bash(ls docs)"))
    }

    @Test func aThreadThatEndsBeforeTheWriteIsNotGrantedOn() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        try await denyInLog(fx, id, ["ls docs"])
        // The decision lands between the caller's view of the thread and the grant: the grant checks again.
        let log = try EventLogWriter.open(at: fx.project.eventsURL(id))
        _ = try await log.append(.reviewDecision, data: ["decision": "abandoned", "by": "user"])
        await log.close()
        await #expect(throws: ThreadServiceError.self) { try await fx.service.grant(id: id, target: "1", scope: .once) }
        #expect(try grantEvents(fx, id).isEmpty)
    }

    @Test func aDecisionOnTheSameThingIsNotRecordedTwice() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        try await denyInLog(fx, id, ["ls docs"])
        let first = try await fx.service.grant(id: id, target: "1", scope: .thread)
        let again = try await fx.service.grant(id: id, target: "1", scope: .thread)
        let once = try await fx.service.grant(id: id, target: "1", scope: .once)
        #expect(first.seq != nil && again.seq == nil && once.seq == nil)
        #expect(try grantEvents(fx, id).count == 1)
    }

    @Test func numbersStayWhereTheyWereWhenMoreIsGrantedOrDenied() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        try await denyInLog(fx, id, ["ls a", "ls b"])
        _ = try await fx.service.grant(id: id, target: "1", scope: .thread)
        try await denyInLog(fx, id, ["ls c", "ls a"])
        let found = try fx.service.grantCandidates(id: id)
        #expect(found.map(\.input) == ["ls a", "ls b", "ls c"])
        #expect(found.map(\.status) == [.granted(.thread), .open, .open])
    }

    @Test func badTargetsAndEndedOrBusyThreadsAreRefusedWithNothingRecorded() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        try await denyInLog(fx, id, ["ls a"])
        for target in ["0", "9", "x", "1.1", "1.", "-1", "1.2.3", ""] {
            await #expect(throws: GrantError.self, "\(target)") {
                try await fx.service.grant(id: id, target: target, scope: .thread)
            }
        }
        #expect(try grantEvents(fx, id).isEmpty)
        let log = try EventLogWriter.open(at: fx.project.eventsURL(id))
        _ = try await log.append(.reviewDecision, data: ["decision": "discarded", "by": "user"])
        await log.close()
        await #expect(throws: ThreadServiceError.self) { try await fx.service.grant(id: id, target: "1", scope: .thread) }
        #expect(try grantEvents(fx, id).isEmpty)
    }
}

@Suite struct GrantPatternDeniedTests {
    @Test func aBroaderDeniedRuleCoversANarrowerPattern() {
        let denied = ["Bash(git push:*)", "Write", "Bash(rm -rf:*)"]
        #expect(GrantPattern.deniedBy("Bash(git push origin x)", denied: denied) == "Bash(git push:*)")
        #expect(GrantPattern.deniedBy("Bash(git push:*)", denied: denied) == "Bash(git push:*)")
        #expect(GrantPattern.deniedBy("Write(a.md)", denied: denied) == "Write")
        #expect(GrantPattern.deniedBy("Bash(rm -rf build)", denied: denied) == "Bash(rm -rf:*)")
        #expect(GrantPattern.deniedBy("Bash(git pull)", denied: denied) == nil)
        #expect(GrantPattern.deniedBy("Edit(a.md)", denied: denied) == nil)
    }

    @Test func theLedgerLeavesOutWhatADeniedRuleCovers() {
        let tools = ToolSet(available: ["Bash"], allowed: [], denied: ["Bash(git push:*)"])
        let event = Event(
            seq: 1, ts: "t", turn: 0, kind: .grantAdded,
            data: ["scope": "thread", "pattern": "Bash(git push origin x)"])
        #expect(GrantLedger(events: [event]).patternsForNextTurn(tools: tools).isEmpty)
    }
}

@Suite struct GrantCLITests {
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

    @Test func listThenGrantThenRefuseWithTheDocumentedExitCodes() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        try await denyInLog(fx, id, ["chmod +x scripts/x.sh && bash -n scripts/x.sh", "rm -rf build"])

        let list = try await cli(["grant", id], in: fx)
        #expect(list.exit?.termination == .exited(0), "\(list.text)")
        #expect(list.text.contains("2 denied commands"), "\(list.text)")
        #expect(list.text.contains("1.1  safe"), "\(list.text)")
        #expect(list.text.contains("grants Bash(chmod +x scripts/x.sh)"), "\(list.text)")
        #expect(list.text.contains("2  unsafe"), "\(list.text)")

        let whole = try await cli(["grant", id, "1", "--thread"], in: fx)
        #expect(whole.exit?.termination == .exited(6), "\(whole.text)")
        let unsafe = try await cli(["grant", id, "2", "--once"], in: fx)
        #expect(unsafe.exit?.termination == .exited(6), "\(unsafe.text)")
        let missing = try await cli(["grant", id, "9", "--once"], in: fx)
        #expect(missing.exit?.termination == .exited(7), "\(missing.text)")
        let noScope = try await cli(["grant", id, "1.1"], in: fx)
        #expect(noScope.exit?.termination == .exited(2), "\(noScope.text)")
        let twoScopes = try await cli(["grant", id, "1.1", "--once", "--thread"], in: fx)
        #expect(twoScopes.exit?.termination == .exited(2), "\(twoScopes.text)")

        let ok = try await cli(["grant", id, "1.1", "--thread"], in: fx)
        #expect(ok.exit?.termination == .exited(0), "\(ok.text)")
        #expect(ok.text.contains("granted for \(id): Bash(chmod +x scripts/x.sh)"), "\(ok.text)")
        #expect(ok.text.contains("workbench send-back"), "\(ok.text)")
        let again = try await cli(["grant", id, "1.1", "--thread"], in: fx)
        #expect(again.text.contains("already on record"), "\(again.text)")

        let dangerous = try await cli(["grant", id, "2", "--once", "--allow-dangerous"], in: fx)
        #expect(dangerous.exit?.termination == .exited(0), "\(dangerous.text)")

        let after = try await cli(["grant", id], in: fx)
        #expect(after.text.contains("[granted: thread]") && after.text.contains("[granted: once]"), "\(after.text)")
        #expect(try grantEvents(fx, id).count == 2)
    }

    @Test func jsonListsTheSameThingsAndTheActiveThreadIsTheDefault() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        try await denyInLog(fx, id, ["ls docs"])
        let ok = try await cli(["grant", "1", "--once", "--json"], in: fx)
        #expect(ok.exit?.termination == .exited(0), "\(ok.text)")
        let result = try JSONDecoder().decode(JSONValue.self, from: Data(ok.text.utf8))
        #expect(result["recorded"] == .bool(true) && result["scope"]?.stringValue == "once")
        #expect(result["pattern"]?.stringValue == "Bash(ls docs)")

        let list = try await cli(["grant", "--json"], in: fx)
        let parsed = try JSONDecoder().decode(JSONValue.self, from: Data(list.text.utf8))
        #expect(parsed["thread"]?.stringValue == id && parsed["v"]?.intValue == 1)
        guard case .array(let denied)? = parsed["denied"], let first = denied.first else {
            Issue.record("\(list.text)")
            return
        }
        #expect(first["status"]?.stringValue == "granted_once" && first["level"]?.stringValue == "safe")
        #expect(first["parts"] != nil)
    }
}
