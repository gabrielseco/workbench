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

    /// What the stage's table asks for that this version does not do yet, said once per round rather than ignored.
    var notYetUsedWarning: String? {
        let keys = config.notYetUsed
        guard !keys.isEmpty else { return nil }
        return "the \(name) stage sets \(keys.joined(separator: ", ")), which this version does not use yet; "
            + "the built-in Codex review ran"
    }
}
