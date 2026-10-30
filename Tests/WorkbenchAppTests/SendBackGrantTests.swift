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

    private func store(_ core: Core, _ fixture: AppFixture) async throws -> ProjectStore {
        let actions = GoalActions(
            loadReview: { _, _ in nil },
            grantCandidates: { _, _ in core.candidates() },
            grant: { _, _, target, scope, dangerous in try core.grant(target, scope, dangerous) })
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
}
