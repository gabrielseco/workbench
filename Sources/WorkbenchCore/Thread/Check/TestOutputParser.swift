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

    mutating func feed(_ line: String) {
        let isPass = line.hasPrefix("✔ Test ")
        guard isPass || line.hasPrefix("✘ Test ") else { return }
        let rest = line.dropFirst("✔ Test ".count)
        guard let name = Self.name(in: rest, verdict: isPass ? " passed after " : " failed after ") else { return }
        // A name that passed and failed (a retry, a parameterized case) is listed once per side.
        guard seen.insert((isPass ? "p:" : "f:") + name).inserted else { return }
        if passed.count + failed.count >= Self.maxNames {
            truncated = true
            return
        }
        if isPass { passed.append(name) } else { failed.append(name) }
    }

    var result: CheckTests { CheckTests(passed: passed, failed: failed, truncated: truncated) }

    /// `name()` or `"display name"` up to the verdict words; nil when the line is not a final result.
    private static func name(in rest: Substring, verdict: String) -> String? {
        guard let end = rest.range(of: verdict) else { return nil }
        var name = rest[..<end.lowerBound].trimmingCharacters(in: .whitespaces)
        if name.count >= 2, name.hasPrefix("\""), name.hasSuffix("\"") { name = String(name.dropFirst().dropLast()) }
        guard !name.isEmpty else { return nil }
        return String(name.prefix(maxNameLength))
    }
}
