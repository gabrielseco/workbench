import Foundation
import Testing

@testable import WorkbenchCore

/// The parser behind Linux's process table. Plain text, so it is checked on every OS, not only where `/proc` exists.
@Suite struct ProcStatTests {
    // pid (comm) state ppid pgrp session tty tpgid flags minflt cminflt majflt cmajflt utime stime cutime cstime priority
    // nice threads itrealvalue starttime ...
    private let plain = "4242 (sleep) S 1 4242 4242 0 -1 4194304 100 0 0 0 0 0 0 0 20 0 1 0 987654 12345 600 18446744073709551615"

    @Test func theFieldsAfterTheCommandNameGiveTheParentAndTheStartTicks() throws {
        let fields = try #require(ProcStat.fields(plain))
        #expect(fields.first == "S")
        #expect(ProcStat.parent(fields) == 1)
        #expect(ProcStat.startTicks(fields) == 987_654)
    }

    @Test func aCommandNameWithSpacesAndParenthesesDoesNotShiftTheFields() throws {
        let odd = "77 (my (odd) prog name) R 55 77 77 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 31337 1 1 1"
        let fields = try #require(ProcStat.fields(odd))
        #expect(fields.first == "R")
        #expect(ProcStat.parent(fields) == 55, "the parent comes after the closing parenthesis of the name")
        #expect(ProcStat.startTicks(fields) == 31_337)
    }

    @Test func aLineThatIsCutOrNotAStatLineGivesNothingRatherThanAWrongNumber() {
        #expect(ProcStat.fields("garbage with no name") == nil)
        let short = ProcStat.fields("9 (x) S 1 2 3")
        #expect(short.flatMap(ProcStat.startTicks) == nil, "too few fields for a start time")
        #expect(short.flatMap(ProcStat.parent) == 1)
        #expect(ProcStat.fields("")?.isEmpty ?? true)
    }
}
