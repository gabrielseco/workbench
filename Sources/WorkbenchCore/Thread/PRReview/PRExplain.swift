import Foundation

/// `explain-pr`: the same read-only agent run as `pr-review --pr`, on the same throwaway checkout of the pull request's
/// head, asked for an explanation instead of a verdict. The output contract is docs/plan/explain-pr.md.
public enum PRExplain {
    /// The folder under `.workbench/` where explanations are kept, one file per pull request and head.
    public static let folderName = "explains"

    /// `pr-<n>-<head7>.md`: a head that has not moved names the same file, so it is reused.
    public static func fileName(pr: Int, head: String) -> String { "pr-\(pr)-\(head.prefix(7)).md" }

    static func prompt(for input: PRReviewInput) -> String {
        var lines = [
            "# Explain pull request #\(input.pr)",
            "",
            "You are explaining a pull request of this repository to someone who is about to review it and has not seen "
                + "it. The working directory is a read-only checkout of its head (\(input.headSHA)), branch "
                + "\(input.branch), to be merged into \(input.base).",
            "Do not run builds or the test suite: read files and the diff only. Do not change files. Do not post "
                + "anything anywhere. `gh` and the network are not available to you.",
            "",
            "The change, as a diff against its base, is saved at \(input.diffPath). Read that file; it is the "
                + "whole change."
                + (input.diffTruncated ? " It was cut at \(PRReview.diffLimit / 1024) KiB." : "")
                + " To read any part of the change again, run `git diff \(input.baseSHA)...\(input.headSHA)` in the checkout.",
            "",
            "## What the author says it is",
            "",
            "The pull request's own title and description, or the spec the person named. It says what was meant; the "
                + "diff says what was done.",
            "",
            PRReview.fenced(input.goal),
        ]
        if let instructions = input.instructions {
            lines += ["", "## Project instructions", "", PRReview.fenced(instructions)]
        }
        lines += [
            "",
            "## What to write",
            "",
            "Markdown, for a reader who knows the project but not this change:",
            "- A level-1 heading that names what the change does, in a few words.",
            "- Summary: two to four sentences on what changes, for whom, and why.",
            "- How it works: the change in the order that is easiest to follow (not file order), naming the files, "
                + "types and functions that matter.",
            "- What to look at: the parts a reviewer should read closely (risky logic, changed behaviour, anything the "
                + "description claims that the diff does not show, or the reverse).",
            "- Tests: what the change adds or changes in its tests and what they prove; say so plainly when there are none.",
            "",
            "Your whole answer is the explanation: plain Markdown, no YAML front matter, nothing before the heading and "
                + "nothing after the last section. Keep it under 150 lines.",
            "",
        ]
        return lines.joined(separator: "\n")
    }

    /// The answer as the file keeps it: the Markdown body alone, trimmed, ending in one newline. A leading YAML front
    /// matter block is dropped, since the caller writes its own and two would break the note. Nil when nothing is left.
    static func body(_ answer: String) -> String? {
        // CRLF lines would keep a `\r` on the fences, so the front matter would not be seen.
        var text = answer.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = text.components(separatedBy: "\n")
        let isFence = { (line: String) in line.trimmingCharacters(in: .whitespaces) == "---" }
        if lines.first.map(isFence) == true, let close = lines.dropFirst().firstIndex(where: isFence) {
            text = lines[(close + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text.isEmpty ? nil : text + "\n"
    }
}

/// What `explain-pr` came to. A failed run is a result with a reason, never a file reported as written.
public struct PRExplainResult: Sendable, Equatable {
    public var pr: Int
    /// The head the explanation is of.
    public var headSHA: String
    /// The explanation's file, absolute; nil when the run failed.
    public var file: URL?
    /// True when the file was kept from an earlier run of the same head and no agent ran.
    public var reused: Bool
    /// Why there is no explanation.
    public var failure: String?
    /// The agent's transcript, relative to the project root; nil when no agent ran.
    public var transcriptPath: String?
    public var warnings: [String]
}
