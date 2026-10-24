import Foundation
import Testing

@testable import WorkbenchCore

private func tempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wb-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func ev(_ seq: Int, _ turn: Int, _ kind: EventKind, _ data: JSONValue = [:]) -> Event {
    Event(seq: seq, ts: "2026-10-24T10:00:\(String(format: "%02d", seq % 60)).000Z", turn: turn, kind: kind, data: data)
}

private func activity(_ type: String, _ fields: [String: JSONValue] = [:]) -> JSONValue {
    var data = fields
    data["provider"] = "codex"
    data["type"] = .string(type)
    return .object(data)
}

@Suite struct AgentActivityEventsTests {
    private func data(_ item: AgentActivity, provider: String = "codex") -> JSONValue? {
        AgentActivityRecord.data(for: item, provider: provider)
    }

    @Test func mapsEveryCase() {
        #expect(data(.started(pid: 4)) == nil, "turn.started has the pid")
        #expect(data(.text("hi")) == activity("text", ["text": "hi"]))
        #expect(data(.tool(name: "shell", summary: "ls")) == activity("tool", ["name": "shell", "summary": "ls"]))
        #expect(data(.permissionDenied(tool: "Bash")) == activity("permission_denied", ["tool": "Bash"]))
        #expect(data(.diagnostic("slow")) == activity("diagnostic", ["text": "slow"]))
        #expect(data(.dropped(count: 3)) == activity("dropped", ["count": 3]))
        let handle = AgentSessionHandle(provider: .codex, purpose: .coding, value: "t-1")
        #expect(data(.session(handle)) == activity("session", ["value": "t-1", "purpose": "coding"]))
        #expect(
            data(.usage(AgentUsage(inputTokens: 1, outputTokens: 2, cachedInputTokens: 3, costUSD: 0.5)))
                == activity("usage", ["input_tokens": 1, "output_tokens": 2, "cached_input_tokens": 3, "cost_usd": 0.5]))
        let gemini = AgentProviderID("gemini")!
        #expect(data(.unknown(provider: gemini, raw: "{}")) == [
            "provider": "gemini", "type": "unknown", "raw": "{}",
        ])
    }

    @Test func boundsRawAndText() throws {
        let long = String(repeating: "x", count: AgentActivityRecord.maxTextCharacters + 10)
        let text = try #require(data(.text(long)))
        #expect(text["text"]?.stringValue?.count == AgentActivityRecord.maxTextCharacters)
        #expect(text["truncated"] == true)
        let unknown = try #require(data(.unknown(provider: .codex, raw: long)))
        #expect(unknown["raw"]?.stringValue?.count == AgentActivityRecord.maxTextCharacters)
        #expect(unknown["raw_truncated"] == true && unknown["provider"] == "codex")
        #expect(try #require(data(.text("short")))["truncated"] == nil)
    }

    @Test func unknownUsageStaysUnknown() throws {
        let partial = try #require(data(.usage(AgentUsage(inputTokens: 10))))
        #expect(partial["output_tokens"] == nil && partial["cached_input_tokens"] == nil && partial["cost_usd"] == nil)
        #expect(LogFormatter.describeActivity(activity("usage")) == "usage: not reported")

        let state = ThreadState.derive(
            from: [
                ev(1, 0, .threadCreated),
                ev(2, 1, .turnStarted, ["provider": "codex"]),
                ev(3, 1, .agentActivity, partial),
                ev(4, 1, .agentActivity, activity("usage", ["input_tokens": 5])),
                ev(5, 1, .turnEnded, ["result": "succeeded"]),
            ], id: "t")
        #expect(state.reportedUsage == AgentUsage(inputTokens: 15), "the fields nobody reported are nil, not 0")
        #expect(state.totalCostUSD == 0 && state.review.turnResult == "succeeded")
        #expect(ThreadState.derive(from: [ev(1, 0, .threadCreated)], id: "t").reportedUsage == nil)
    }

    @Test func oneShapePerTurn() {
        let claudeTool: JSONValue = [
            "type": "assistant", "message": ["content": [["type": "tool_use", "name": "Bash", "input": ["command": "ls"]]]],
        ]
        let state = ThreadState.derive(
            from: [
                ev(1, 0, .threadCreated),
                ev(2, 1, .turnStarted, ["provider": "claude"]),
                ev(3, 1, .claude, claudeTool),
                ev(4, 1, .agentActivity, activity("tool", ["name": "shell", "summary": "ls"])),
                ev(5, 1, .agentActivity, activity("permission_denied", ["tool": "Bash"])),
            ], id: "t")
        #expect(state.progress.toolCalls == 1, "the legacy line counts; the normalized copy does not")
        #expect(state.progress.deniedCalls == 0 && state.progress.deniedCallsKnown)
    }

    @Test func hugeCountsSaturateInsteadOfTrapping() {
        let state = ThreadState.derive(
            from: [
                ev(1, 0, .threadCreated), ev(2, 1, .turnStarted, ["provider": "codex"]),
                ev(3, 1, .agentActivity, activity("usage", ["input_tokens": .int(Int.max), "output_tokens": -4])),
                ev(4, 1, .agentActivity, activity("usage", ["input_tokens": 1])),
            ], id: "t")
        #expect(state.reportedUsage == AgentUsage(inputTokens: Int.max), "a negative count is ignored")
    }

    @Test func aGapKeepsTheCountsUnknown() {
        let progress = ThreadState.derive(
            from: [
                ev(1, 0, .threadCreated), ev(2, 1, .turnStarted, ["provider": "codex"]),
                ev(3, 1, .agentActivity, activity("tool", ["name": "shell"])),
                ev(4, 1, .agentActivity, activity("dropped", ["count": 40])),
                ev(5, 1, .agentActivity, activity("tool", ["name": "shell"])),
                ev(6, 1, .agentActivity, activity("permission_denied", ["tool": "Bash"])),
            ], id: "t").progress
        #expect(!progress.toolCallsKnown && !progress.deniedCallsKnown, "what was dropped cannot be counted back in")
    }

    @Test func aReplayThroughTheFileMatchesTheEventsWithoutActivity() async throws {
        let url = try tempDir().appendingPathComponent("events.jsonl")
        let log = try EventLogWriter.open(at: url)
        try await log.append(.threadCreated)
        try await log.append(.turnStarted, turn: 1, data: ["provider": "codex"])
        let mark = try await log.nextSeq
        for item: AgentActivity in [.text("hi"), .tool(name: "shell", summary: "ls"), .diagnostic("note")] {
            try await log.append(.agentActivity, turn: 1, data: try #require(data(item)))
        }
        try await log.append(.turnEnded, turn: 1, data: ["result": "succeeded"])
        let events = try EventLogReader.read(at: url).events
        #expect(mark == 3)
        var with = ThreadState.derive(from: events, id: "t")
        var without = ThreadState.derive(from: events.filter { $0.kind != .agentActivity }, id: "t")
        #expect(with.progress.toolCalls == 1 && without.progress.toolCalls == 0)
        (with.progress, without.progress) = (Progress(), Progress())
        #expect(with == without)
    }

    @Test func normalizedTurnProgress() {
        let start = [ev(1, 0, .threadCreated), ev(2, 1, .turnStarted, ["provider": "codex"])]
        let quiet = ThreadState.derive(from: start, id: "t").progress
        #expect(!quiet.toolCallsKnown && !quiet.deniedCallsKnown, "nothing reported is unknown, not 0")

        #expect(quiet.lines(timeout: nil, now: Date()).last == "tools:     unknown calls, unknown denied")

        let busy = ThreadState.derive(
            from: start + [
                ev(3, 1, .agentActivity, activity("text", ["text": "thinking"])),
                ev(4, 1, .agentActivity, activity("tool", ["name": "shell", "summary": "ls"])),
                ev(5, 1, .agentActivity, activity("tool", ["name": "shell", "summary": "pwd"])),
            ], id: "t").progress
        #expect(busy.toolCalls == 2 && busy.toolCallsKnown && !busy.deniedCallsKnown)
        #expect(busy.lastEvent == "tool_use shell pwd" && busy.lastEventAt == "2026-10-24T10:00:05.000Z")

        let denied = ThreadState.derive(
            from: start + [ev(3, 1, .agentActivity, activity("permission_denied", ["tool": "Bash"]))], id: "t").progress
        #expect(denied.deniedCalls == 1 && denied.deniedCallsKnown)
    }

    @Test func fixtureReplaysSameState() {
        let claudeTool: JSONValue = [
            "type": "assistant", "message": ["content": [["type": "tool_use", "name": "Bash", "input": ["command": "ls"]]]],
        ]
        let normalized: [Event] = [
            ev(20, 2, .agentActivity, activity("text", ["text": "hello"])),
            ev(21, 2, .agentActivity, activity("tool", ["name": "shell", "summary": "ls"])),
            ev(22, 2, .agentActivity, activity("usage", ["output_tokens": 9])),
            ev(23, 2, .agentActivity, activity("hologram", ["x": 1])),
            ev(24, 2, "agent.future" as EventKind, ["whatever": true]),
        ]
        let legacy: [Event] = [
            ev(10, 0, .threadCreated), ev(11, 1, .turnStarted, ["provider": "claude", "session_id": "s"]),
            ev(12, 1, .claude, claudeTool), ev(13, 1, .turnEnded, ["result": "succeeded", "cost_usd": 0.25]),
        ]
        let turnTwo: [Event] = [
            ev(18, 2, .turnStarted, ["provider": "codex", "session_id": "c"]),
        ]
        let end = ev(30, 2, .turnEnded, ["result": "succeeded"])
        let without = ThreadState.derive(from: legacy + turnTwo + [end], id: "t")
        var with = ThreadState.derive(from: legacy + turnTwo + normalized + [end], id: "t")

        // What activity feeds is progress and reported usage; everything else is the same.
        #expect(with.reportedUsage == AgentUsage(outputTokens: 9) && without.reportedUsage == nil)
        #expect(with.progress.toolCalls == 1)
        with.progress = without.progress
        with.reportedUsage = nil
        #expect(with == without)

        // A log with only `claude` lines, as written before this kind existed, reads as it did.
        let ended = ev(14, 1, .turnEnded, ["result": "succeeded", "cost_usd": 0.25])
        let old = ThreadState.derive(from: Array(legacy[0...2]) + [ended], id: "t")
        let ignored = ThreadState.derive(
            from: Array(legacy[0...2]) + [ev(13, 1, .agentActivity, activity("tool", ["name": "x"])), ended], id: "t")
        #expect(old.progress.toolCalls == 1 && ignored.progress.toolCalls == 1)
        #expect(old.progress.lastEvent == ignored.progress.lastEvent, "activity in a legacy turn is ignored whole")
    }

    @Test func recorderChoosesOneShape() async throws {
        for provider in ["codex", "claude"] {
            let dir = try tempDir()
            let log = try EventLogWriter.open(at: dir.appendingPathComponent("events.jsonl"))
            try await log.append(.turnStarted, turn: 1)
            let store = ThreadStore(project: Project(root: dir))
            try FileManager.default.createDirectory(at: store.project.threadDirectory("t"), withIntermediateDirectories: true)
            let transcript = TranscriptWriter(url: TranscriptFile.url(in: store.project.threadDirectory("t"), turn: 1))
            let recorder = TurnRecorder(
                log: log, transcript: transcript, turn: 1, sessionID: "s", provider: provider, threadID: "t", store: store,
                notify: { _ in })
            try await recorder.record(
                .line(#"{"type":"system"}"#), activity: [.text("hi"), .unknown(provider: .codex, raw: "?")])
            try await recorder.record(.oversized(preview: "abc", totalBytes: 9_000_000), activity: [])
            try await recorder.flush()
            let events = try EventLogReader.read(at: dir.appendingPathComponent("events.jsonl")).events.dropFirst()
            #expect(recorder.sawOutput)
            if provider == "claude" {
                // The lines are in the turn's transcript, verbatim, in order; neither is the turn's result line, so
                // the log holds none, and there is no normalized copy.
                #expect(events.isEmpty)
                let lines = TranscriptFile.lines(
                    at: TranscriptFile.url(in: store.project.threadDirectory("t"), turn: 1), turn: 1)
                let marker: JSONValue = ["truncated": true, "original_bytes": 9_000_000, "prefix": "abc"]
                #expect(lines.map(\.data) == [["type": "system"], marker])
                #expect(transcript.summary?.lines == 2)
            } else {
                #expect(events.map(\.kind) == [.agentActivity, .agentActivity, .agentActivity])
                #expect(events.map { $0.data["type"]?.stringValue } == ["text", "unknown", "diagnostic"])
            }
        }
    }
}

// MARK: the cap, with a child nobody reads

private struct NoisyProvider: AgentProvider {
    var id = AgentProviderID("fake")!
    var capabilities = AgentCapabilities(policies: [.scopedCoding], resume: .none, streamsActivity: true)

    func invocation(for request: AgentRequest) throws -> AgentInvocation {
        AgentInvocation(
            executable: "/bin/sh",
            arguments: ["-c", "i=0; while [ $i -lt 3000 ]; do echo line$i; i=$((i+1)); done"],
            environment: ["PATH": "/usr/bin:/bin"], displayArguments: ["-c", "<script>"])
    }

    func makeDecoder(for request: AgentRequest) -> any AgentDecoder { NoisyDecoder() }
}

private struct NoisyDecoder: AgentDecoder {
    mutating func consume(line: String) -> [AgentActivity] { [.text(line)] }
    mutating func consume(oversizedPreview preview: String, totalBytes: Int) -> [AgentActivity] { [] }
    mutating func finish(exit: ProcessExit) -> AgentDecoderResult { AgentDecoderResult(outcome: .succeeded) }
}

private final class Clock: @unchecked Sendable {
    var date = Date(timeIntervalSince1970: 1_000_000)
}

@Suite(.processGate) struct AgentActivityCapTests {
    @Test func aTurnPastTheCapStillShowsSignsOfLife() async throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent("events.jsonl")
        let log = try EventLogWriter.open(at: url)
        try await log.append(.turnStarted, turn: 1, data: ["provider": "fake"])
        let clock = Clock()
        let recorder = TurnRecorder(
            log: log, transcript: TranscriptWriter(url: dir.appendingPathComponent("t.jsonl")), turn: 1, sessionID: "s",
            provider: "fake", threadID: "t", store: ThreadStore(project: Project(root: dir)),
            notify: { _ in }, now: { clock.date })
        for _ in 0..<(AgentActivityRecord.maxPerTurn + 5) {
            try await recorder.record(.line("x"), activity: [.tool(name: "shell", summary: "ls")])
        }
        func dropped() throws -> [Event] {
            try EventLogReader.read(at: url).events.filter { $0.data["type"] == "dropped" }
        }
        #expect(try dropped().isEmpty, "inside the interval nothing more is written")
        clock.date.addTimeInterval(AgentActivityRecord.dropMarkInterval + 1)
        try await recorder.record(.line("x"), activity: [.text("still going")])
        let marks = try dropped()
        #expect(marks.count == 1 && marks[0].data["count"]?.intValue == 6)
        let state = ThreadState.derive(from: try EventLogReader.read(at: url).events, id: "t")
        #expect(state.progress.lastEvent?.hasSuffix("6 activity item(s) not recorded") == true)
        #expect(!state.progress.toolCallsKnown, "past the cap the count is a floor, so it is not shown as known")
    }

    @Test func capAndSlowConsumer() async throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent("events.jsonl")
        let log = try EventLogWriter.open(at: url)
        try await log.append(.turnStarted, turn: 1)
        let store = ThreadStore(project: Project(root: dir))
        let recorder = TurnRecorder(
            log: log, transcript: TranscriptWriter(url: dir.appendingPathComponent("t.jsonl")), turn: 1, sessionID: "s",
            provider: "fake", threadID: "t", store: store, notify: { _ in })
        let request = AgentRequest(
            provider: AgentProviderID("fake")!, prompt: "go", workingDirectory: dir, outputDirectory: dir,
            policy: .scopedCoding, spend: .timeoutOnly, purpose: .coding, environment: [:],
            limits: AgentLimits(timeout: 60, maxBufferedActivity: 8))
        let execution = try AgentRunner.start(provider: NoisyProvider(), request: request, recorder: recorder)
        let completion = await execution.completion  // nobody reads `execution.activity`
        try await recorder.flush()

        #expect(completion.succeeded, "the child ended with no consumer")
        let events = try EventLogReader.read(at: url).events.filter { $0.kind == .agentActivity }
        #expect(events.count == AgentActivityRecord.maxPerTurn + 1)
        let last = try #require(events.last)
        #expect(last.data["type"] == "dropped" && last.data["count"]?.intValue == 3000 - AgentActivityRecord.maxPerTurn)
        #expect(last.data["reason"] == "cap")
    }
}
