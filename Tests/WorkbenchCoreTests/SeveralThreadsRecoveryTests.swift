import Foundation
import Testing

@testable import WorkbenchCore

/// A crash with several threads in a turn leaves several logs open. Each thread's log is its own, so each is closed on its own,
/// once, and no thread's recovery touches another's.
@Suite struct SeveralThreadsRecoveryTests {
    @Test func everyOpenTurnEndsOnceAndNoOtherLogIsTouched() async throws {
        let root = Scratch.url("recovery").resolvingSymlinksInPath()
        let project = Project(root: root)
        let ids = ["g-2026-11-08-a", "g-2026-11-08-b", "g-2026-11-08-c"]
        for id in ids {
            let log = try EventLogWriter.open(at: project.eventsURL(id))
            try await log.append(.threadCreated, data: ["repo": .string(root.path)])
            try await log.append(.turnStarted, turn: 1, data: [:])
            await log.close()
        }
        // The third thread's turn had ended before the crash: nothing to recover there.
        let closed = try EventLogWriter.open(at: project.eventsURL(ids[2]))
        try await closed.append(.turnEnded, turn: 1, data: ["result": "succeeded"])
        await closed.close()
        let before = try Data(contentsOf: project.eventsURL(ids[2]))

        var recovered: [String: Event] = [:]
        for id in ids.prefix(2) {
            let log = try EventLogWriter.open(at: project.eventsURL(id))
            if let ended = try await log.recoverOrphanedTurn() { recovered[id] = ended }
            #expect(try await log.recoverOrphanedTurn() == nil, "a second recovery finds nothing")
            await log.close()
        }
        #expect(Set(recovered.keys) == Set(ids.prefix(2)))
        for id in ids.prefix(2) {
            let kinds = try EventLogReader.read(at: project.eventsURL(id)).events.map(\.kind.rawValue)
            #expect(kinds.filter { $0 == "turn.started" }.count == 1)
            #expect(kinds.filter { $0 == "turn.ended" }.count == 1, "exactly one turn.ended per turn.started: \(kinds)")
            #expect(recovered[id]?.data["result"]?.stringValue == "interrupted")
        }
        #expect(try Data(contentsOf: project.eventsURL(ids[2])) == before, "a thread that had nothing open was left alone")
    }
}
