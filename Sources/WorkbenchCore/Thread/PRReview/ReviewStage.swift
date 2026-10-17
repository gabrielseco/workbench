import Foundation

/// A review stage: a read-only reviewer over declared inputs whose answer ends in a verdict line
/// (docs/plan/P6-review-stages.md). The runner in `ThreadService+PRReview.swift` runs a stage; `pr-review` is the
/// first instance and, until stages get events of their own, the only one it can record.
public struct ReviewStage: Sendable, Equatable {
    /// The events one round is recorded with.
    struct Events: Sendable, Equatable {
        var started: EventKind
        var finished: EventKind

        static let prReview = Events(started: .prReviewStarted, finished: .prReviewFinished)
    }

    public var name: String
    public var config: ReviewStageConfig
    var events: Events

    /// The stage's folder in the thread's directory; the paths its events record are relative to the thread and
    /// start with it.
    var folder: String { name }

    /// `pr-review` as the config defines it: the built-in brief, with `[review.stage.pr-review]` (or `[pr_review]`)
    /// for its checklist and round cap.
    public static func prReview(_ config: Config) -> ReviewStage {
        ReviewStage(name: ReviewConfig.prReviewStage, config: config.review.prReview, events: .prReview)
    }

    /// The brief for one round.
    func brief(for input: PRReviewInput) -> String { PRReview.prompt(for: input) }

    static let skillHeader =
        "This rubric comes from a skill written to be run by hand. Ignore any step in it that builds, runs, "
        + "installs or posts anything: read the files and the diff, and report."

    /// The rubric a stage's file gives: a prompt file whole; a skill file's `## Rubric` section when it has one,
    /// else the whole skill under a header saying to skip what a read-only reviewer cannot do. Nil when that is empty.
    func rubric(from text: String) -> String? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard config.skill != nil else { return text }
        let lines = text.components(separatedBy: "\n")
        let heading = { (line: String) in line.hasPrefix("# ") || line.hasPrefix("## ") }
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "## Rubric" }) else {
            return Self.skillHeader + "\n\n" + text
        }
        let rest = lines[(start + 1)...]
        let section = rest.prefix { !heading($0) }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return section.isEmpty ? nil : section
    }

    /// What the stage's table asks for that this version does not do yet, said once per round rather than ignored.
    var notYetUsedWarning: String? {
        let keys = config.notYetUsed
        guard !keys.isEmpty else { return nil }
        return "the \(name) stage sets \(keys.joined(separator: ", ")), which this version does not use yet; "
            + "the built-in Codex review ran"
    }
}
