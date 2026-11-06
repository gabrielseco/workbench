import Foundation
import Testing

@testable import WorkbenchCore

@Suite struct TaskRunDetailTests {
    private let started = Date(timeIntervalSince1970: 1_793_000_000)

    private func run(thread: String?, ended: TimeInterval? = 90) -> TaskHistory.Run {
        TaskHistory.Run(
            started: started, ended: ended.map { started.addingTimeInterval($0) }, pullRequest: nil, trigger: "tick",
            outcome: ended == nil ? nil : .failed, reason: nil, units: [], thread: thread)
    }

    /// A thread log with a setup, a failed check whose output is a file, and two turns with a cost each.
    private func thread(
        in project: Project, id: String = "g-x", checkOutput: String = "boom\n", summary: String = "the final answer",
        costs: [JSONValue] = [0.25, 0.5], denials: Int = 1
    ) async throws {
        let log = try EventLogWriter.open(at: project.eventsURL(id))
        try await log.append(.setupRan, data: ["result": "passed", "duration_ms": 3000])
        let folder = project.threadDirectory(id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try checkOutput.write(to: folder.appendingPathComponent("check.txt"), atomically: true, encoding: .utf8)
        let call: JSONValue = .object(["tool_name": "Bash", "tool_input": .object(["command": "pnpm run x"])])
        for (index, cost) in costs.enumerated() {
            let turn = index + 1
            try await log.append(.turnStarted, turn: turn, data: ["pid": 1])
            var data: [String: JSONValue] = ["result": "succeeded", "cost_usd": cost]
            if turn == costs.count {
                data["summary"] = .string(summary)
                data["denials"] = .array(Array(repeating: call, count: denials))
            }
            try await log.append(.turnEnded, turn: turn, data: .object(data))
        }
        try await log.append(.checkStarted, turn: 1)
        try await log.append(.checkRan, turn: 1, data: ["result": "failed", "duration_ms": 5000, "output_ref": "check.txt"])
        await log.close()
    }

    @Test func readsWhatTheRunDid() async throws {
        let project = Project(root: try Scratch.directory("detail"))
        let lines = (1...12).map { "line \($0)" }.joined(separator: "\n") + "\n"
        try await thread(in: project, checkOutput: lines)
        let detail = TaskRunDetail.read(project: project, run: run(thread: "g-x"))
        #expect(detail.source == .read && detail.duration == 90)
        #expect(detail.costUSD == 0.75, "the turns' costs are added")
        #expect(detail.setup == TaskRunDetail.Step(result: "passed", seconds: 3))
        #expect(detail.check?.result == "failed" && detail.check?.seconds == 5)
        #expect(detail.check?.tail == (5...12).map { "line \($0)" }, "the last \(TaskExplanation.maxCheckLines) lines")
        #expect(detail.denied == 1 && detail.agentMessage == "the final answer")
    }

    @Test func anUnknownCostIsNotZero() async throws {
        let project = Project(root: try Scratch.directory("cost"))
        try await thread(in: project, costs: [.null])
        #expect(TaskRunDetail.read(project: project, run: run(thread: "g-x")).costUSD == nil)
        // One turn that reported and one that did not: what is known, not a guess for the rest.
        let some = Project(root: try Scratch.directory("cost-some"))
        try await thread(in: some, costs: [.null, 0.5])
        #expect(TaskRunDetail.read(project: some, run: run(thread: "g-x")).costUSD == 0.5)
    }

    @Test func aRunWithoutAThread() async throws {
        let project = Project(root: try Scratch.directory("nothread"))
        let none = TaskRunDetail.read(project: project, run: run(thread: nil))
        #expect(none == TaskRunDetail(source: .noThread, duration: 90))
        let gone = TaskRunDetail.read(project: project, run: run(thread: "g-gone"))
        #expect(gone.source == .removed && gone.setup == nil && gone.check == nil && gone.agentMessage == nil)
        // A name that is not a thread id is never turned into a path.
        let unsafe = TaskRunDetail.read(project: project, run: run(thread: "../../etc"))
        #expect(unsafe.source == .noThread)
    }

    @Test func aRunStillGoing() async throws {
        let project = Project(root: try Scratch.directory("going"))
        try await thread(in: project)
        let detail = TaskRunDetail.read(project: project, run: run(thread: "g-x", ended: nil))
        #expect(detail.duration == nil, "no end, no duration")
        #expect(detail.source == .read, "what its thread has so far is still shown")
        #expect(TaskRunDetail.read(project: project, run: run(thread: nil, ended: nil)) == TaskRunDetail(source: .noThread))
    }

    @Test func resultWordsFromAnEditedLogAreCleaned() async throws {
        let project = Project(root: try Scratch.directory("words"))
        let log = try EventLogWriter.open(at: project.eventsURL("g-x"))
        let bad = JSONValue.string("passed\u{1B}[31m\nsecond line " + String(repeating: "z", count: 500))
        try await log.append(.setupRan, data: ["result": bad, "duration_ms": 1000])
        try await log.append(.turnStarted, turn: 1, data: ["pid": 1])
        try await log.append(.turnEnded, turn: 1, data: ["result": "succeeded"])
        try await log.append(.checkStarted, turn: 1)
        try await log.append(.checkRan, turn: 1, data: ["result": bad, "duration_ms": 1000])
        await log.close()
        let detail = TaskRunDetail.read(project: project, run: run(thread: "g-x"))
        for word in [detail.setup?.result, detail.check?.result] {
            let text = try #require(word)
            #expect(!text.contains("\u{1B}") && !text.contains("\n") && text.count <= 40, "\(text)")
        }
    }

    @Test func outputIsCleanedAndBounded() async throws {
        let project = Project(root: try Scratch.directory("clean"))
        let output = "red \u{1B}[31mtext\n" + String(repeating: "x", count: 5_000) + "\n"
        let said = "start \u{1B}[2J" + String(repeating: "y\n", count: 5_000)
        try await thread(in: project, checkOutput: output, summary: said)
        let detail = TaskRunDetail.read(project: project, run: run(thread: "g-x"))
        let tail = try #require(detail.check?.tail)
        #expect(tail.allSatisfy { !$0.contains("\u{1B}") && $0.count <= TaskExplanation.maxCheckLine })
        let message = try #require(detail.agentMessage)
        #expect(!message.contains("\u{1B}") && !message.contains("\n") && message.count <= TaskExplanation.maxMessage)
    }
}
