import Foundation

/// A proof that names tests the project check runs: `test: Suite/name, other`. The output of `swift test`
/// carries no suite, so only the part after the last `/` is compared; a trailing `*`, `…` or `()` is dropped.
/// A name matches a test that equals it or starts with it, so `everythingOrder` covers a family of tests.
public enum TestProof {
    /// The names a typed proof lists: nil when the proof is not of this form or names nothing usable.
    public static func names(in proof: String) -> [String]? {
        let trimmed = proof.trimmingCharacters(in: .whitespaces)
        guard let match = trimmed.wholeMatch(of: #/(?i)test:\s*(.+)/#) else { return nil }
        let names = match.1.split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { normalize(String($0)) }
        return names.isEmpty ? nil : names
    }

    /// The fallback for a proof written as prose: it counts only when every word is a recorded test name or
    /// filler, so "and the doc is updated" stays for a person. Old goals are written this way.
    static func namesInProse(_ proof: String, known: CheckTests) -> [String]? {
        let recorded = Set((known.passed + known.failed).map(baseName))
        var names: [String] = []
        for word in proof.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "_" || $0 == "'" || $0 == "/") }) {
            let text = String(word)
            if let name = normalize(text), recorded.contains(name) {
                names.append(name)
            } else if !proseFiller.contains(text.lowercased()) {
                return nil
            }
        }
        return names.isEmpty ? nil : names
    }

    /// Passed when every name matches a test and all matches passed; failed when any match failed; nil when a
    /// name matches nothing, since a test that did not appear says nothing.
    static func verdict(for names: [String], in tests: CheckTests) -> CriterionStatus.State? {
        var anyFailed = false
        for name in names {
            let passed = tests.passed.contains { matches(name, $0) }
            let failed = tests.failed.contains { matches(name, $0) }
            if !passed && !failed { return nil }
            if failed { anyFailed = true }
        }
        return anyFailed ? .failed : .passed
    }

    private static func matches(_ name: String, _ test: String) -> Bool { baseName(test).hasPrefix(name) }

    /// `name()` or `name(arg:)` as the runner prints it, without the parameters.
    private static func baseName(_ test: String) -> String {
        String(test.prefix(while: { $0 != "(" }))
    }

    private static func normalize(_ raw: String) -> String? {
        var text = Substring(raw.trimmingCharacters(in: CharacterSet(charactersIn: "`'\".;:")))
        if let slash = text.lastIndex(of: "/") { text = text[text.index(after: slash)...] }
        var name = String(text)
        while let last = name.last, "*…)(.".contains(last) { name.removeLast() }
        return name.wholeMatch(of: #/[A-Za-z_][A-Za-z0-9_]*/#) == nil ? nil : name
    }

    private static let proseFiller: Set<String> = [
        "test", "tests", "unit", "pass", "passes", "passed", "and", "the", "in", "a", "named", "ran", "run",
        "covers", "cover", "case", "cases", "is", "are", "green",
    ]
}
