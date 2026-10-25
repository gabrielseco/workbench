import Foundation
import Testing

@testable import WorkbenchCore

private func result(_ denials: [JSONValue]) -> JSONValue {
    ["type": "result", "permission_denials": .array(denials)]
}

private func denial(_ tool: String, _ input: JSONValue? = nil, id: String? = nil) -> JSONValue {
    var fields: [String: JSONValue] = ["tool_name": .string(tool)]
    if let input { fields["tool_input"] = input }
    if let id { fields["tool_use_id"] = .string(id) }
    return .object(fields)
}

private func state(
    _ lines: [(turn: Int, JSONValue)], end: String = "succeeded", recorded full: [Int: JSONValue] = [:]
) -> ThreadState {
    var events: [Event] = []
    func add(_ kind: EventKind, _ turn: Int, _ data: JSONValue) {
        events.append(Event(seq: events.count + 1, ts: "2026-10-14T10:00:00.000Z", turn: turn, kind: kind, data: data))
    }
    add(.threadCreated, 0, [:])
    for turn in Set(lines.map(\.turn)).sorted() {
        add(.turnStarted, turn, ["session_id": "s", "resume": .bool(turn > 1)])
        for line in lines where line.turn == turn { add(.claude, turn, line.1) }
        // What the runner records: the length of the turn's last result array.
        var recorded = 0
        if let last = lines.last(where: { $0.turn == turn }), case .array(let items)? = last.1["permission_denials"] {
            recorded = items.count
        }
        var ended: [String: JSONValue] = ["result": .string(end), "permission_denials": .int(recorded)]
        if let calls = full[turn] { ended["denials"] = calls }
        add(.turnEnded, turn, .object(ended))
    }
    return ThreadState.derive(from: events, id: "t")
}

private func rendered(_ state: ThreadState) -> [String] {
    ReviewReport(
        state: state, title: "T", criteria: [], approval: "approved", goalProblem: nil,
        diff: .unavailable(reason: "x")
    ).render()
}

@Suite(.processGate) struct DeniedToolsTests {
    @Test func aTurnWithoutClaudeLinesReadsItsRefusedCallsFromTurnEnded() {
        func event(_ seq: Int, _ turn: Int, _ kind: EventKind, _ data: JSONValue = [:]) -> Event {
            Event(seq: seq, ts: "2026-10-25T10:00:00.000Z", turn: turn, kind: kind, data: data)
        }
        let calls: JSONValue = .array([
            ["tool": "Bash", "input": "git push origin main"], ["tool": "Bash", "input": "git push origin main"],
            ["tool": "Write"],
        ])
        let events = [
            event(1, 0, .threadCreated), event(2, 1, .turnStarted, ["provider": "claude"]),
            event(3, 1, .turnEnded, ["result": "succeeded", "permission_denials": 3, "denials": calls]),
        ]
        let tools = ThreadState.derive(from: events, id: "t").review.deniedTools
        #expect(tools.map(\.tool) == ["Bash", "Bash", "Write"])
        #expect(tools[0].input == "git push origin main" && tools[0].fullInput == "git push origin main")
        #expect(tools[0].identity == tools[1].identity && tools[0].identity != tools[2].identity)
        #expect(tools.allSatisfy { $0.seq == 3 && $0.turn == 1 })
        #expect(tools[2].input == nil)
    }

    @Test func grantCandidatesReadATurnEndedWithNoClaudeLines() {
        let push: JSONValue = ["tool": "Bash", "input": "git push origin main"]
        let calls: JSONValue = .array([push, push])
        let events = [
            Event(seq: 1, ts: "2026-10-25T10:00:00.000Z", turn: 0, kind: .threadCreated, data: [:]),
            Event(seq: 2, ts: "2026-10-25T10:00:00.000Z", turn: 1, kind: .turnStarted, data: ["provider": "claude"]),
            Event(
                seq: 3, ts: "2026-10-25T10:00:01.000Z", turn: 1, kind: .turnEnded,
                data: ["result": "succeeded", "denials": calls]),
        ]
        let candidates = GrantCandidates.derive(events: events)
        #expect(candidates.count == 1, "equal refusals are one candidate")
        #expect(candidates.first?.seqs == [3, 3])
        #expect(candidates.first?.assessment.parts.first?.command.contains("git push") == true)
    }

    @Test func aDenialShowsWhatItWasDeniedFor() {
        let push = denial("Bash", ["command": "git push origin main"])
        let s = state([(1, result([push, push, denial("Write", ["file_path": "/etc/hosts"])]))])
        let lines = rendered(s)
        #expect(lines.contains("Denied     3 tool calls"), "\(lines)")
        #expect(lines.contains { $0.hasPrefix("  Bash(git push origin main) ×2  turn 1, seq ") }, "\(lines)")
        #expect(lines.contains { $0.hasPrefix("  Write(/etc/hosts) ×1  turn 1, seq ") }, "\(lines)")
        #expect(lines.contains { $0.contains("workbench log t --seq") })
    }

    @Test func aLongDeniedCommandIsShownWholeUnderItsEntry() throws {
        let command = "chmod +x scripts/verify-cli/abandon.sh && bash -n scripts/verify-cli/abandon.sh && echo syntax-ok; "
            + "command -v shellcheck && shellcheck scripts/verify-cli/abandon.sh; scripts/verify-cli/abandon.sh"
        let s = state(
            [(1, result([denial("Bash", ["command": .string(command)])]))],
            recorded: [1: [["tool": "Bash", "input": .string(command)]]])
        #expect(s.review.deniedTools[0].fullInput == command)
        let lines = rendered(s)
        let at = try #require(lines.firstIndex { $0.contains("×1") })
        let body = lines[(at + 1)...].prefix { $0.hasPrefix("      ") }
        #expect(body.count >= 2, "\(lines)")
        #expect(body.allSatisfy { $0.count <= 102 })
        #expect(body.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ") == "Bash(\(command))")
    }

    @Test func aShortCommandIsNotRepeatedAndAnOldLogStillRenders() {
        let call = result([denial("Bash", ["command": "git push origin main"])])
        let short = state([(1, call)], recorded: [1: [["tool": "Bash", "input": "git push origin main"]]])
        #expect(!rendered(short).contains { $0.hasPrefix("      ") })
        let old = state([(1, call)])
        #expect(old.review.deniedTools[0].fullInput == nil)
        #expect(rendered(old).contains { $0.hasPrefix("  Bash(git push origin main) ×1") })
    }

    @Test func aGroupTakesTheFullCommandFromAnyTurnThatRecordedIt() {
        let long = String(repeating: "word ", count: 40) + "end"
        let call = result([denial("Bash", ["command": .string(long)])])
        let s = state([(1, call), (2, call)], recorded: [2: [["tool": "Bash", "input": .string(long)]]])
        #expect(s.review.deniedTools.map(\.fullInput) == [nil, long])
        #expect(rendered(s).contains { $0.hasPrefix("      ") })
    }

    @Test func theFullInputIsMadeSafeToPrint() {
        let call = result([denial("Bash", ["command": "echo hi"])])
        let s = state([(1, call)], recorded: [1: [["tool": "Bash", "input": "\u{1B}[31mecho\u{07}\nhi\tthere"]]])
        #expect(s.review.deniedTools[0].fullInput == "echo hi there")
    }

    @Test func fullInputsFromAnotherListAreNotAttached() {
        let call = result([denial("Bash", ["command": "ls"]), denial("Bash", ["command": "pwd"])])
        let s = state([(1, call)], recorded: [1: [["tool": "Bash", "input": "something else entirely"]]])
        #expect(s.review.deniedTools.allSatisfy { $0.fullInput == nil })
    }

    @Test func oddShapesStillShowTheToolAndNeverBreakTheLine() {
        let huge = String(repeating: "x", count: 5_000)
        let s = state([(1, result([
            denial("A"), denial("B", 7), denial("C", ["command": 3]), denial("D", ["command": .string(huge)]),
            denial("E", ["command": "\u{1B}[31mred\u{1B}[0m\nsecond\tline\u{07}"]), ["tool_input": "no name"],
        ]))])
        let tools = s.review.deniedTools
        #expect(tools.map(\.tool) == ["A", "B", "C", "D", "E"])
        #expect(tools[0].input == nil && tools[1].input == nil && tools[2].input == nil)
        #expect((tools[3].input ?? "").count <= 100)
        #expect(tools[4].input == "red second line", "\(String(describing: tools[4].input))")
        for line in rendered(s) {
            #expect(!line.contains("\u{2028}") && !line.contains("\u{1B}"))
            #expect(!line.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }, "\(line.debugDescription)")
        }
    }

    @Test func longInputsThatDifferOnlyAfterTheCutAreTwoDenials() {
        let prefix = String(repeating: "a", count: 150)
        let s = state([(1, result([
            denial("Write", ["file_path": .string(prefix + "1")]), denial("Write", ["file_path": .string(prefix + "2")]),
            denial("Bash", ["command": "ls  -l"]), denial("Bash", ["command": "ls -l"]),
        ]))])
        let lines = rendered(s).filter { $0.contains("×") }
        #expect(lines.count == 4, "\(lines)")
    }

    @Test func eachTurnsEntriesMatchItsRecordedCountEvenWhenAResumeIsDeniedTheSameCallAgain() {
        let call = result([denial("Bash", ["command": "git push"], id: "toolu_1")])
        let s = state([(1, call), (2, call)], end: "failed")
        #expect(s.review.deniedTools.map(\.turn) == [1, 2])
        #expect(rendered(s).contains { $0.contains("denied tools may explain this") })
    }

    @Test func aReplayedResultLineIsCountedOnceAndEntriesMatchEachTurnsRecordedCount() {
        let withID = result([denial("Bash", ["command": "rm -rf /"], id: "toolu_1")])
        let noID = result([denial("Bash", ["command": "git push"])])
        let two = result([denial("Bash", ["command": "ls"]), denial("Bash", ["command": "ls"])])
        let s = state([(1, withID), (1, withID), (2, noID), (2, noID), (3, two)])
        #expect(s.review.deniedTools.map(\.turn) == [1, 2, 3, 3])
        for turn in 1...3 {
            let recorded = s.review.deniedTools.filter { $0.turn == turn }.count
            #expect(recorded == (turn == 3 ? 2 : 1))
        }
    }

    @Test func aStalledTurnSaysDeniedToolsMayExplainIt() {
        let denied = [(1, result([denial("Bash", ["command": "git push"])]))]
        #expect(rendered(state(denied, end: "timed_out")).contains { $0.contains("denied tools may explain this") })
        #expect(!rendered(state(denied, end: "succeeded")).contains { $0.contains("may explain") })
        #expect(rendered(state([(1, result([]))], end: "stopped")).contains("Denied     none"))
    }
}

@Suite(.processGate) struct DeniedToolsCommandTests {
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

    @Test func theSeqInReviewOpensTheRawEvent() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        _ = try await fx.runner(id).run(fx.options())
        let log = try EventLogWriter.open(at: fx.project.eventsURL(id))
        _ = try await log.append(.turnStarted, turn: 2, data: ["session_id": "s", "resume": true])
        let seq = try await log.append(
            .claude, turn: 2, data: result([denial("Bash", ["command": "git push origin main"], id: "toolu_9")])).seq
        _ = try await log.append(.turnEnded, turn: 2, data: ["result": "succeeded"])
        await log.close()

        let review = try await cli(["review", id], in: fx)
        #expect(review.text.contains("Bash(git push origin main) ×1  turn 2, seq \(seq)"), "\(review.text)")

        let raw = try await cli(["log", id, "--seq", String(seq)], in: fx)
        #expect(raw.exit?.termination == .exited(0), "\(raw.text)")
        #expect(raw.text.contains("toolu_9") && raw.text.contains("git push origin main"), "\(raw.text)")
        #expect(raw.text.contains("\"seq\" : \(seq)"), "\(raw.text)")

        let missing = try await cli(["log", id, "--seq", "9999"], in: fx)
        #expect(missing.exit?.termination == .exited(7))
        let junk = try await cli(["log", id, "--seq", "abc"], in: fx)
        #expect(junk.exit?.termination != .exited(0))
    }
}
