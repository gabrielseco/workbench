import Foundation
import Testing

@testable import WorkbenchCore

struct TaskFileTests {
    private static func task(_ front: String, body: String = "Bump the next countries.") -> String {
        "---\n\(front)\n---\n\(body)\n"
    }

    private func problems(_ text: String) -> [String] {
        do {
            _ = try TaskDefinition.parse(text, name: "bump")
            return []
        } catch let error as TaskParseError {
            return error.problems.map(\.description)
        } catch {
            return ["\(error)"]
        }
    }

    @Test func aFullTaskParses() throws {
        let text = Self.task(
            """
            at: 04:00
            days: weekdays
            batch: 2
            include: .claude/skills/bump/SKILL.md
            inputs: [countries.txt, "fixtures/"]
            pending: .workbench/tasks/bump/pending.sh
            fix: pr
            budget: 3.50
            """)
        let task = try TaskDefinition.parse(text, name: "bump")
        #expect(task.schedule == .daily(at: TimeOfDay(hour: 4, minute: 0), days: Set(2...6)))
        #expect(task.batch == 2 && task.fix == .pr && task.budgetUSD == Decimal(string: "3.5"))
        #expect(task.include == ".claude/skills/bump/SKILL.md" && task.pending == ".workbench/tasks/bump/pending.sh")
        #expect(task.inputs == ["countries.txt", "fixtures/"])
        #expect(task.instructions == "Bump the next countries.")
    }

    @Test func theDefaultsAreTheSafeOnes() throws {
        let task = try TaskDefinition.parse(Self.task("batch: 1"), name: "bump")
        #expect(task.fix == .report && task.schedule == nil && task.pending == nil && task.inputs.isEmpty)
    }

    @Test func anUnknownKeyIsRefusedAndNamed() {
        let found = problems(Self.task("at: 04:00\nmerge: yes"))
        #expect(found.contains { $0.contains("unknown key 'merge'") })
    }

    @Test func badValuesAreRefusedWithTheKeyNamed() {
        for (front, key) in [
            ("batch: 0", "batch"), ("batch: 99", "batch"), ("fix: merge", "fix"), ("budget: -1", "budget"),
            ("at: 25:00", "at"), ("at: 04:00\ndays: someday", "days"), ("every: 2s", "every"), ("every: 90d", "every"),
            ("days: weekdays", "days"),
        ] {
            let found = problems(Self.task(front))
            #expect(found.contains { $0.contains("'\(key)'") }, "\(front) -> \(found)")
        }
    }

    @Test func anIntervalTooBigToMultiplyIsRefusedNotTrapped() {
        for value in ["9223372036854775807d", "99999999999999999999h", "3000000m", "9223372036854775807m"] {
            let found = problems(Self.task("every: \(value)"))
            #expect(found.contains { $0.contains("'every'") }, "every: \(value) -> \(found)")
        }
    }

    @Test func atAndEveryTogetherAreRefused() {
        let found = problems(Self.task("at: 04:00\nevery: 1h"))
        #expect(found.contains { $0.contains("either 'at' or 'every'") })
    }

    @Test func pathsOutsideTheProjectAreRefused() {
        for value in ["/etc/passwd", "../outside.sh", "a/../../b", "-rf", "~/x", "a//b", "dir/"] {
            #expect(!problems(Self.task("pending: \(value)")).isEmpty, "pending: \(value)")
        }
        for key in ["include", "inputs"] {
            #expect(!problems(Self.task("\(key): ../outside")).isEmpty, "\(key)")
        }
        #expect(problems(Self.task("inputs: [a, ../b]")).contains { $0.contains("'inputs'") })
    }

    @Test func tooManyInputsAreRefused() {
        let many = (0..<21).map { "f\($0).txt" }.joined(separator: ", ")
        #expect(problems(Self.task("inputs: [\(many)]")).contains { $0.contains("'inputs'") })
    }

    @Test func aTaskWithoutInstructionsOrFrontMatterIsRefused() {
        #expect(problems("---\nbatch: 1\n---\n\n").contains { $0.contains("no instructions") })
        #expect(!problems("just text").isEmpty)
    }

    @Test func aBadTaskNameIsRefused() {
        #expect(throws: TaskParseError.self) { try TaskDefinition.parse(Self.task("batch: 1"), name: "../x") }
    }

    @Test func everyProblemIsReportedAtOnce() {
        let found = problems(Self.task("batch: 0\nfix: merge\nmerge: yes"))
        #expect(found.count == 3)
    }
}
