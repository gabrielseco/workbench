import Foundation
import Testing

@testable import WorkbenchApp
@testable import WorkbenchCore

/// What a grant call saw, and the decisions core "has on record" for the next read of the candidates.
private final class Core: @unchecked Sendable {
    private let lock = NSLock()
    private var base: [GrantCandidate]
    private var decided: [String: GrantScope] = [:]
    private var calls: [String] = []
    var refusal: String?

    init(_ candidates: [GrantCandidate]) { base = candidates }

    var seen: [String] { lock.withLock { calls } }

    func candidates() -> [GrantCandidate] {
        lock.withLock {
            base.map { candidate in
                var shown = candidate
                shown.parts = candidate.parts.map { part in
                    var part = part
                    if let scope = decided[part.number] { part.status = scope == .never ? .refused : .granted(scope) }
                    return part
                }
                return shown
            }
        }
    }

    func grant(_ target: String, _ scope: GrantScope, _ dangerous: Bool) throws {
        try lock.withLock {
            calls.append("\(target) \(scope.rawValue) \(dangerous)")
            if let refusal { throw GoalActions.RefusalText(refusal) }
            decided[target] = scope
        }
    }
}

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var runOptions: [RunOptions] = []
    func add(_ options: RunOptions) { lock.withLock { runOptions.append(options) } }
    var options: [RunOptions] { lock.withLock { runOptions } }
}

private actor Gate {
    private var opened = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func open() {
        opened = true
        waiting.forEach { $0.resume() }
        waiting = []
    }
}

@MainActor private var keptFixtures: [AppFixture] = []

@MainActor @Suite struct SendBackGrantTests {
    private static let denials: JSONValue = [
        ["tool": "Bash", "input": "npm test"],
        ["tool": "Bash", "input": "npm run lint && npm run build"],
        ["tool": "Bash", "input": "git push origin main"],
    ]

    private func ended() async throws -> AppFixture {
        let fixture = try await AppFixture()
        try await fixture.addThread("t1", approved: true)
        try fixture.append("t1", .turnStarted, turn: 1, data: ["session_id": "s1"])
        try fixture.append(
            "t1", .turnEnded, turn: 1,
            data: ["result": "succeeded", "permission_denials": 3, "denials": Self.denials])
        keptFixtures.append(fixture)
        return fixture
    }

    private func candidates(_ fixture: AppFixture) throws -> [GrantCandidate] {
        GrantCandidates.derive(events: try EventLogReader.read(at: fixture.project.eventsURL("t1")).events)
    }

    private func store(
        _ core: Core, _ fixture: AppFixture, gate: Gate? = nil, recorder: Recorder? = nil
    ) async throws -> ProjectStore {
        let actions = GoalActions(
            makeRun: { _, _, options in
                recorder?.add(options)
                return RunHandle(run: {}, stop: {})
            },
            loadReview: { _, _ in nil },
            grantCandidates: { _, _ in core.candidates() },
            grant: { _, _, target, scope, dangerous in
                await gate?.wait()
                try core.grant(target, scope, dangerous)
            })
        let store = ProjectStore(preferences: MemoryPreferences(projectPath: nil), actions: actions)
        #expect(await store.open(fixture.root))
        return store
    }

    @Test func rowsFollowTheDeniedCandidates() async throws {
        let fixture = try await ended()
        let store = try await store(Core(try candidates(fixture)), fixture)
        await store.loadSendBackGrants()
        // A compound is decided a part at a time; a plain call is one row.
        #expect(store.sendBackGrants.map(\.number) == ["1", "2.1", "2.2", "3"])
        #expect(store.sendBackGrants.map(\.command) == ["npm test", "npm run lint", "npm run build", "git push origin main"])
    }

    @Test func aChoiceIsRecordedThroughCore() async throws {
        let fixture = try await ended()
        let core = Core(try candidates(fixture))
        let store = try await store(core, fixture)
        await store.loadSendBackGrants()
        await store.decide(store.sendBackGrants[0], .thread)
        #expect(core.seen == ["1 thread false"])
        #expect(store.sendBackGrants[0].decided == "Allowed for this thread" && store.sendBackGrants[0].refusal == nil)
        await store.decide(store.sendBackGrants[1], .never)
        #expect(store.sendBackGrants[1].decided == "Never")
    }

    @Test func aRefusalShowsOnItsRowAndRecordsNothing() async throws {
        let fixture = try await ended()
        let core = Core(try candidates(fixture))
        core.refusal = "Bash(npm test) is blocked by [tools] denied"
        let store = try await store(core, fixture)
        await store.loadSendBackGrants()
        await store.decide(store.sendBackGrants[0], .once)
        #expect(store.sendBackGrants[0].refusal == "Bash(npm test) is blocked by [tools] denied")
        #expect(store.sendBackGrants[0].status == .open && store.sendBackGrants[1].refusal == nil)
        // The next read is core's own: nothing decided, so the refusal goes with it.
        core.refusal = nil
        await store.loadSendBackGrants()
        #expect(store.sendBackGrants.allSatisfy { $0.status == .open && $0.refusal == nil })
    }

    @Test func anUnsafePartNeedsItsOwnConfirmAndOnlyOnce() async throws {
        let fixture = try await ended()
        let core = Core(try candidates(fixture))
        let store = try await store(core, fixture)
        await store.loadSendBackGrants()
        let push = try #require(store.sendBackGrants.first { $0.command == "git push origin main" })
        // The card offers it only once (`onlyOnce`) and asks first; what it sends then says it was confirmed.
        #expect(push.level == .unsafe && push.onlyOnce)
        #expect(store.sendBackGrants.filter(\.onlyOnce).map(\.command) == ["git push origin main"])
        await store.decide(push, .once, dangerous: true)
        #expect(core.seen == ["3 once true"])
        // A choice that was not confirmed carries no such flag.
        await store.decide(store.sendBackGrants[0], .once)
        #expect(core.seen.last == "1 once false")
    }

    @Test func aDecisionOutlivesTheCard() async throws {
        let fixture = try await ended()
        let core = Core(try candidates(fixture))
        let store = try await store(core, fixture)
        store.sendingBack = true
        await store.loadSendBackGrants()
        await store.decide(store.sendBackGrants[0], .thread)
        store.cancelSendBack()
        #expect(!store.sendingBack && store.sendBackGrants.isEmpty)
        // Opened again, the card reads core's record: the decision is still there, and was made once.
        await store.loadSendBackGrants()
        #expect(store.sendBackGrants[0].status == .granted(.thread) && core.seen == ["1 thread false"])
    }

    @Test func codexThreadsShowNoGrants() async throws {
        let fixture = try await ended()
        let project = fixture.project
        let offered = try await GoalActions.core.grantCandidates(project, "t1")
        #expect(!offered.isEmpty)
        try FileManager.default.createDirectory(
            at: project.configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "[tools]\navailable = [\"Read\", \"Bash\"]\n[agents.run]\nprovider = \"codex\"\n".write(
            to: project.configURL, atomically: true, encoding: .utf8)
        #expect(try await GoalActions.core.grantCandidates(project, "t1").isEmpty)
    }

    @Test func aThreadWithNoDeniedCallsHasNoRows() async throws {
        let fixture = try await AppFixture()
        try await fixture.addThread("t1", approved: true)
        try fixture.turn("t1", 1)
        keptFixtures.append(fixture)
        let store = try await store(Core(try candidates(fixture)), fixture)
        await store.loadSendBackGrants()
        // No rows is what the card leaves its whole section out for.
        #expect(store.sendBackGrants.isEmpty)
    }

    @Test func aSendWaitsForADecisionStillBeingSaved() async throws {
        let fixture = try await ended()
        let (gate, recorder) = (Gate(), Recorder())
        let store = try await store(Core(try candidates(fixture)), fixture, gate: gate, recorder: recorder)
        await store.loadSendBackGrants()
        store.sendingBack = true
        store.sendBackNote = "go on"
        let first = store.sendBackGrants[0]
        let pending = Task { await store.decide(first, .once) }
        for _ in 0..<100 where store.grantsInFlight == 0 { await Task.yield() }
        #expect(store.grantsInFlight == 1)
        // Neither another decision nor the send gets past it, and the card stays up with the note.
        await store.decide(store.sendBackGrants[1], .once)
        store.sendBack()
        #expect(recorder.options.isEmpty && store.sendingBack && store.sendBackNote == "go on")
        await gate.open()
        await pending.value
        store.sendBack()
        #expect(recorder.options.first?.feedback == "go on" && !store.sendingBack)
    }

    @Test func aRefusalThatArrivesAfterLeavingTheProjectIsNotShownThere() async throws {
        let (first, second) = (try await ended(), try await ended())
        let core = Core(try candidates(first))
        core.refusal = "refused"
        let gate = Gate()
        let store = try await store(core, first, gate: gate)
        await store.loadSendBackGrants()
        let pending = Task { await store.decide(store.sendBackGrants[0], .once) }
        for _ in 0..<100 where store.grantsInFlight == 0 { await Task.yield() }
        #expect(await store.open(second.root))
        await store.loadSendBackGrants()
        await gate.open()
        await pending.value
        // Both projects have a row `1`: the other one's refusal is not this one's.
        #expect(store.sendBackGrants.allSatisfy { $0.refusal == nil })
    }

    // MARK: Core itself

    private func coreStore(_ fixture: AppFixture, config: String) async throws -> ProjectStore {
        let project = fixture.project
        try FileManager.default.createDirectory(
            at: project.configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try config.write(to: project.configURL, atomically: true, encoding: .utf8)
        let store = ProjectStore(preferences: MemoryPreferences(projectPath: nil), actions: .core)
        #expect(await store.open(fixture.root))
        return store
    }

    @Test func aChoiceIsAGrantAddedEventInTheLogAndTheNextReadSeesIt() async throws {
        let fixture = try await ended()
        let store = try await coreStore(fixture, config: "[tools]\navailable = [\"Read\", \"Bash\"]\n")
        await store.loadSendBackGrants()
        await store.decide(store.sendBackGrants[0], .thread)
        let events = try EventLogReader.read(at: fixture.project.eventsURL("t1")).events
        let added = try #require(events.last { $0.kind == .grantAdded })
        #expect(added.data["scope"]?.stringValue == "thread" && added.data["by"]?.stringValue == "user")
        #expect(store.sendBackGrants[0].status == .granted(.thread) && store.sendBackGrants[0].refusal == nil)
    }

    @Test func coresRefusalsReachTheRowAndRecordNothing() async throws {
        let fixture = try await ended()
        let store = try await coreStore(fixture, config: "[tools]\navailable = [\"Read\", \"Bash\"]\ndenied = [\"Bash\"]\n")
        await store.loadSendBackGrants()
        // A pattern the project denies is not overridden by a grant.
        await store.decide(store.sendBackGrants[0], .once)
        #expect(store.sendBackGrants[0].refusal?.contains("[tools] denied") == true)
        // A thread that has been decided takes no more grants.
        try fixture.decide("t1", "accepted")
        await store.decide(store.sendBackGrants[0], .never)
        let ended = try #require(store.sendBackGrants[0].refusal)
        #expect(!ended.isEmpty && !ended.contains("[tools] denied"))
        let events = try EventLogReader.read(at: fixture.project.eventsURL("t1")).events
        #expect(!events.contains { $0.kind == .grantAdded })
    }
}
