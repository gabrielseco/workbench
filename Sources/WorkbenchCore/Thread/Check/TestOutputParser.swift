import Foundation

/// The tests a check run saw finish, read from the runner's output. Names are what the runner prints, so a
/// proof is matched against them as written; a list cut at the bound says so and then backs no verdict.
public struct CheckTests: Sendable, Equatable {
    public var passed: [String] = []
    public var failed: [String] = []
    public var truncated = false

    public init(passed: [String] = [], failed: [String] = [], truncated: Bool = false) {
        self.passed = passed
        self.failed = failed
        self.truncated = truncated
    }

    public var isEmpty: Bool { passed.isEmpty && failed.isEmpty }
}

/// Reads `swift test` output line by line. This is the one seam for another runner: a type with the same
/// `feed` and `result` would replace it. Swift Testing prints the final line of a test as
/// `✔ Test name() passed after …` or `✘ Test name() failed after …`, without the suite; the earlier
/// `recorded an issue` lines are not final and are ignored.
struct TestOutputParser {
    static let maxNames = 2000
    static let maxNameLength = 200

    private var passed: [String] = []
    private var failed: [String] = []
    private var seen: Set<String> = []
    private var truncated = false

    /// The process stream was cut, so lines after the cut were never seen: a failure may be among them.
    mutating func markIncomplete() { truncated = true }

    mutating func feed(_ line: String) {
        if let (name, isPass) = Self.xctest(line) {
            record(name, isPass: isPass)
            return
        }
        let isPass = line.hasPrefix("✔ Test ")
        guard isPass || line.hasPrefix("✘ Test ") else { return }
        let rest = line.dropFirst("✔ Test ".count)
        guard let name = Self.name(in: rest, verdict: isPass ? " passed after " : " failed after ") else { return }
        record(name, isPass: isPass)
    }

    private mutating func record(_ name: String, isPass: Bool) {
        // Past the bound nothing is kept, the set included.
        if passed.count + failed.count >= Self.maxNames {
            truncated = true
            return
        }
        // A name that passed and failed (a retry, a parameterized case) is listed once per side.
        guard seen.insert((isPass ? "p:" : "f:") + name).inserted else { return }
        if isPass { passed.append(name) } else { failed.append(name) }
    }

    var result: CheckTests { CheckTests(passed: passed, failed: failed, truncated: truncated) }

    /// XCTest: `Test Case '-[Suite testName]' passed (0.001 seconds).` (macOS) or `Test Case 'Suite.testName' passed`
    /// (Linux). The name is the test method; `started` lines and suite lines are not results.
    private static func xctest(_ line: String) -> (String, Bool)? {
        let pattern = #/Test Case '(?:-\[)?[^'\s\]]*?[. ]?([A-Za-z_][A-Za-z0-9_]*)\]?' (passed|failed) .*/#
        guard let match = line.wholeMatch(of: pattern) else { return nil }
        return (String(match.1), match.2 == "passed")
    }

    /// `name()` or `"display name"` up to the verdict words; nil when the line is not a final result.
    private static func name(in rest: Substring, verdict: String) -> String? {
        guard let end = rest.range(of: verdict) else { return nil }
        var name = rest[..<end.lowerBound].trimmingCharacters(in: .whitespaces)
        if name.count >= 2, name.hasPrefix("\""), name.hasSuffix("\"") { name = String(name.dropFirst().dropLast()) }
        guard !name.isEmpty else { return nil }
        return String(name.prefix(maxNameLength))
    }
}
