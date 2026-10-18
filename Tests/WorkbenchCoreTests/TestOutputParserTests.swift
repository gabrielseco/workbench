import Foundation
import Testing

@testable import WorkbenchCore

private func parse(_ lines: [String]) -> CheckTests {
    var parser = TestOutputParser()
    lines.forEach { parser.feed($0) }
    return parser.result
}

@Suite struct TestOutputParserTests {
    @Test func swiftTestingFinalLinesAreRead() {
        let tests = parse([
            "◇ Test run started.",
            "◇ Test aThing() started.",
            "✔ Test aThing() passed after 0.001 seconds.",
            "✘ Test other(arg:) recorded an issue at X.swift:1:2: Expectation failed",
            "✘ Test other(arg:) failed after 0.002 seconds with 1 issue.",
            "✔ Test \"a display name\" passed after 0.001 seconds.",
            "✔ Suite S passed after 0.001 seconds.",
        ])
        #expect(tests.passed == ["aThing()", "a display name"])
        #expect(tests.failed == ["other(arg:)"])
        #expect(!tests.truncated)
    }

    @Test func outputInAnUnknownFormatRecordsNothing() {
        let tests = parse(["Test Case '-[S t]' passed (0.001 seconds).", "Executed 1 test", "ok"])
        #expect(tests.isEmpty)
    }

    @Test func aRepeatedLineIsListedOnce() {
        let line = "✔ Test a() passed after 0.001 seconds."
        #expect(parse([line, line]).passed == ["a()"])
    }

    @Test func listsAreBoundedAndSayWhenCut() {
        let lines = (0..<(TestOutputParser.maxNames + 5)).map { "✔ Test t\($0)() passed after 0.001 seconds." }
        let tests = parse(lines)
        #expect(tests.passed.count == TestOutputParser.maxNames)
        #expect(tests.truncated)
    }

    @Test func aLongNameIsCut() {
        let name = String(repeating: "x", count: 500)
        let tests = parse(["✔ Test \(name)() passed after 1 seconds."])
        #expect(tests.passed[0].count == TestOutputParser.maxNameLength)
    }
}
