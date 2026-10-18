import Foundation

/// The text of `workbench grant` with no arguments.
public enum GrantReport {
    public static func render(threadID: String, candidates: [GrantCandidate]) -> [String] {
        guard !candidates.isEmpty else { return ["Thread \(threadID): no denied commands."] }
        let count = candidates.count
        var lines = [
            "Thread \(threadID): \(count) denied command\(count == 1 ? "" : "s"). Nothing here is allowed until granted.", "",
        ]
        for candidate in candidates {
            lines.append(contentsOf: render(candidate))
        }
        lines.append("")
        lines.append("Decide with `workbench grant <number> --once | --thread | --never`.")
        lines.append(
            "A compound is granted one part at a time (`grant 2.1 --thread`). `unsafe` needs --allow-dangerous and is once only.")
        return lines
    }

    /// Text from the log made safe for a terminal: one line, no control characters.
    public static func printable(_ text: String, limit: Int = 400) -> String { ThreadState.safeLine(text, limit: limit) }

    static func render(_ candidate: GrantCandidate) -> [String] {
        let assessment = candidate.assessment
        let text = ThreadState.safeLine(candidate.input ?? "", limit: 4000)
        let shown = text.count > 90 ? String(text.prefix(89)) + "…" : text
        var head = "  \(candidate.number)  \(pad(level(assessment.level)))  \(candidate.tool)(\(shown))"
        if let mark = mark(candidate.status) { head += "  [\(mark)]" }
        var lines = [head]
        if text.count > 90 { lines.append(contentsOf: ReviewReport.wrap(text, width: 90).map { "        " + $0 }) }
        if assessment.isCompound {
            lines.append("        several commands in one; grant a part:")
            for part in candidate.parts { lines.append(contentsOf: render(part, indent: "          ")) }
        } else if let part = candidate.parts.first {
            lines.append(contentsOf: renderDetail(part, indent: "        "))
        } else {
            lines.append("        " + (assessment.reasons.first ?? "nothing to grant"))
        }
        return lines
    }

    private static func render(_ part: GrantCandidate.Part, indent: String) -> [String] {
        let command = ThreadState.safeLine(part.command, limit: 4000)
        let shown = command.count > 70 ? String(command.prefix(69)) + "…" : command
        var head = "\(indent)\(part.number)  \(pad(level(part.level)))  \(shown)"
        if let mark = mark(part.status) { head += "  [\(mark)]" }
        return [head] + renderDetail(part, indent: indent + "      ")
    }

    private static func renderDetail(_ part: GrantCandidate.Part, indent: String) -> [String] {
        var lines: [String] = []
        if let pattern = part.pattern {
            lines.append("\(indent)grants \(ThreadState.safeLine(pattern, limit: 400))")
        } else {
            lines.append("\(indent)cannot be granted as written")
        }
        for reason in part.reasons { lines.append("\(indent)- \(ThreadState.safeLine(reason, limit: 200))") }
        return lines
    }

    public static func level(_ level: DeniedCommandAssessment.Level) -> String {
        switch level {
        case .safe: "safe"
        case .caution: "caution"
        case .unsafe: "unsafe"
        }
    }

    private static func pad(_ text: String) -> String { text.padding(toLength: 7, withPad: " ", startingAt: 0) }

    private static func mark(_ status: GrantStatus) -> String? {
        switch status {
        case .open: nil
        case .granted(let scope): "granted: \(scope.rawValue)"
        case .refused: "never"
        }
    }
}
