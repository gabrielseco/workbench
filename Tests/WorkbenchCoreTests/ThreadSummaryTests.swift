import Foundation
import Testing

@testable import WorkbenchCore

private func tempProject() throws -> Project {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wb-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return Project(root: dir)
}

private func openLog(_ id: String, in project: Project) throws -> EventLogWriter {
    try FileManager.default.createDirectory(at: project.threadDirectory(id), withIntermediateDirectories: true)
    return try EventLogWriter.open(at: project.eventsURL(id))
}

@Suite struct ThreadSummaryTests {
    @Test func aSummaryAgreesWithAFullReplay() async throws {
        let project = try tempProject()
        let store = ThreadStore(project: project)
        let log = try openLog("g-a", in: project)
        try await log.append(
            .threadCreated, data: ["parent": "g-root", "root": "g-root", "round": 2])
        try await log.append(.turnStarted, turn: 1)
        // A verbatim claude line that quotes the kinds must not change the summary.
        _ = try await log.appendClaudeLine(
            #"{"type":"user","text":"thread.created review.decision {\"decision\":\"accepted\"}"}"#, turn: 1)
        try await log.append(.turnEnded, turn: 1, data: ["result": "succeeded"])
        try await log.append(.reviewDecision, data: ["decision": "accepted"])

        let summary = store.summary(of: "g-a")
        let state = store.state(of: "g-a")
        #expect(summary.createdAt == state.createdAt && summary.createdAt != nil)
        #expect(summary.lineage == state.lineage && summary.lineage?.round == 2)
        #expect(summary.decision == "accepted" && !summary.isActive)
    }

    @Test func aQuotedDecisionDoesNotEndTheThread() async throws {
        let project = try tempProject()
        let store = ThreadStore(project: project)
        let log = try openLog("g-b", in: project)
        try await log.append(.threadCreated)
        try await log.append(.turnStarted, turn: 1)
        _ = try await log.appendClaudeLine(
            #"{"type":"user","text":"\"kind\":\"review.decision\",\"data\":{\"decision\":\"discarded\"}"}"#, turn: 1)
        #expect(store.summary(of: "g-b").isActive)
        #expect(store.activeThreadID() == "g-b")
    }

    @Test func unknownDecisionsAndMissingLogsAreInactiveAndEmpty() async throws {
        let project = try tempProject()
        let store = ThreadStore(project: project)
        let log = try openLog("g-c", in: project)
        try await log.append(.threadCreated)
        try await log.append(.reviewDecision, data: ["decision": "maybe"])
        try FileManager.default.createDirectory(at: project.threadDirectory("g-d"), withIntermediateDirectories: true)
        #expect(store.summary(of: "g-c").isActive == store.state(of: "g-c").isActive)
        #expect(store.summary(of: "g-d") == ThreadStore.Summary(id: "g-d"))
    }

    @Test func followUpsAndTheNewestThreadComeFromSummaries() async throws {
        let project = try tempProject()
        let store = ThreadStore(project: project)
        for (id, data): (String, JSONValue) in [
            ("g-root", [:]),
            ("g-r1", ["parent": "g-root", "root": "g-root", "round": 1]),
            ("g-r2", ["parent": "g-r1", "root": "g-root", "round": 2]),
        ] {
            let log = try openLog(id, in: project)
            try await log.append(.threadCreated, data: data)
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(store.rootID(of: "g-r2") == "g-root")
        #expect(store.followUps(of: "g-root").map(\.id) == ["g-r1", "g-r2"])
        #expect(store.newestThreadID() == "g-r2")
    }

    @Test func aLastLineWithoutItsNewlineIsNotAnEvent() async throws {
        let project = try tempProject()
        let store = ThreadStore(project: project)
        let log = try openLog("g-e", in: project)
        try await log.append(.threadCreated)
        await log.close()
        // A complete event whose newline never reached the disk: the writer's repair drops it, so does a summary.
        let decision = Event(
            seq: 2, ts: "2026-10-24T00:00:00.000Z", turn: 0, kind: .reviewDecision, data: ["decision": "accepted"])
        let handle = try FileHandle(forWritingTo: project.eventsURL("g-e"))
        try handle.seekToEnd()
        try handle.write(contentsOf: JSONEncoder().encode(decision))
        #expect(store.summary(of: "g-e").isActive)
        try handle.write(contentsOf: Data("\n".utf8))
        try handle.close()
        #expect(store.summary(of: "g-e").decision == "accepted")
    }

    @Test func aLineQuotingBothKindsAndTheLastDecisionStillWin() async throws {
        let project = try tempProject()
        let store = ThreadStore(project: project)
        let log = try openLog("g-f", in: project)
        try await log.append(.threadCreated)
        try await log.append(.turnStarted, turn: 1)
        _ = try await log.appendClaudeLine(
            #"{"type":"user","text":"thread.created and review.decision in one line"}"#, turn: 1)
        try await log.append(.turnEnded, turn: 1, data: ["result": "succeeded"])
        try await log.append(.reviewDecision, data: ["decision": "discarded"])
        let summary = store.summary(of: "g-f")
        #expect(summary.decision == "discarded")
        #expect(summary == ThreadStore.Summary(
            id: "g-f", createdAt: store.state(of: "g-f").createdAt, lineage: nil, decision: "discarded"))
    }
}
