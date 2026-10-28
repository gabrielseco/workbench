import Foundation
import WorkbenchCore

@testable import WorkbenchApp

/// A throwaway git repository with a `.workbench` folder, and threads written as the real files: a goal and an event log.
@MainActor final class AppFixture {
    let root: URL
    var project: Project { Project(root: root.resolvingSymlinksInPath()) }
    private var counters: [String: Int] = [:]
    private var created = 0

    init(git: Bool = true, workbench: Bool = true) async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("app-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if git { _ = try await GitRunner.discover().run(["init", "-q", "-b", "main"], in: root) }
        if workbench {
            try FileManager.default.createDirectory(
                at: project.threadsDirectory, withIntermediateDirectories: true)
        }
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func goalText(id: String, approved: Bool, title: String? = nil, proofs: [String]? = nil) throws -> String {
        let all = proofs ?? ["test: Thing/works"]
        let criteria = all.enumerated().map { index, proof in
            "- [c\(index + 1)] It works\(all.count > 1 ? " \(index + 1)" : "").\n  - proof: \(proof)"
        }.joined(separator: "\n")
        let draft = """
            ---
            id: \(id)
            title: \(title ?? "Thread \(id)")
            base: main
            budget_usd: 5
            turn_timeout_min: 30
            ---

            ## Request

            Do the thing.

            ## Criteria

            \(criteria)

            ## Out of scope

            - Everything else.

            """
        guard approved else { return draft }
        let hash = try GoalFile.parse(draft).goal.contentHash
        return draft.replacingOccurrences(
            of: "turn_timeout_min: 30\n", with: "turn_timeout_min: 30\nstatus: approved\napproved_hash: \(hash)\n")
    }

    /// Creates the thread with `thread.created` and its goal, and returns it for more events.
    @discardableResult
    func addThread(
        _ id: String, approved: Bool = false, title: String? = nil, proofs: [String]? = nil
    ) async throws -> String {
        let directory = project.threadDirectory(id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let text = try goalText(id: id, approved: approved, title: title, proofs: proofs)
        try text.write(to: project.goalURL(id), atomically: true, encoding: .utf8)
        created += 1
        try append(id, .threadCreated, ts: "2026-10-28T10:00:\(String(format: "%02d", created)).000Z")
        if approved { try append(id, .goalApproved, data: ["hash": "h1"]) }
        return id
    }

    func append(_ id: String, _ kind: EventKind, turn: Int = 0, data: JSONValue = [:], ts: String? = nil) throws {
        let seq = counters[id, default: 0] + 1
        counters[id] = seq
        let event = Event(
            seq: seq, ts: ts ?? "2026-10-28T11:00:00.000Z", turn: turn, kind: kind, data: data)
        // Sorted keys: the same fixture must be the same bytes on every run and machine, or committed fixtures would never match.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        var line = try encoder.encode(event)
        line.append(UInt8(ascii: "\n"))
        let url = project.eventsURL(id)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } else {
            try line.write(to: url)
        }
    }

    func turn(_ id: String, _ n: Int, result: String = "succeeded", cost: Double? = 1.5) throws {
        try append(id, .turnStarted, turn: n, data: ["session_id": "s1"])
        var ended: [String: JSONValue] = ["result": .string(result)]
        if let cost { ended["cost_usd"] = .double(cost) }
        try append(id, .turnEnded, turn: n, data: .object(ended))
    }

    func activity(_ id: String, _ data: [String: JSONValue], turn: Int = 1) throws {
        var data = data
        data["provider"] = "claude"
        try append(id, .agentActivity, turn: turn, data: .object(data))
    }

    func decide(_ id: String, _ decision: String) throws {
        try append(id, .reviewDecision, data: ["decision": .string(decision)])
    }

    func ship(_ id: String, number: Int = 7) throws {
        try append(
            id, .prOpened,
            data: ["url": .string("https://example.test/pull/\(number)"), "number": .int(number), "head_sha": "abc123"])
    }

    func overwriteLog(_ id: String, with text: String) throws {
        try text.write(to: project.eventsURL(id), atomically: true, encoding: .utf8)
    }
}
