import Foundation

/// A review stage: a read-only reviewer over declared inputs whose answer ends in a verdict line
/// (docs/plan/P6-review-stages.md). The runner in `ThreadService+PRReview.swift` runs a stage; `pr-review` is the
/// first instance and keeps its `pr_review.*` events, every other stage is recorded as `review_stage.*`.
public struct ReviewStage: Sendable, Equatable {
    /// The events one round is recorded with.
    struct Events: Sendable, Equatable {
        var started: EventKind
        var finished: EventKind
        /// The `stage` field the events carry, so stages that share the kinds count apart; nil for `pr_review.*`.
        var stage: String?

        static let prReview = Events(started: .prReviewStarted, finished: .prReviewFinished, stage: nil)

        static func stage(_ name: String) -> Events {
            Events(started: .reviewStageStarted, finished: .reviewStageFinished, stage: name)
        }

        /// Whether `event` is a round of this stage, started or finished.
        func owns(_ event: Event) -> Bool {
            guard event.kind == started || event.kind == finished else { return false }
            return stage == nil || event.data["stage"]?.stringValue == stage
        }
    }

    public var name: String
    public var config: ReviewStageConfig
    var events: Events

    /// The stage's folder in the thread's directory; the paths its events record are relative to the thread and
    /// start with it.
    var folder: String { name }

    var isPRReview: Bool { name == ReviewConfig.prReviewStage }

    /// The `verdict` a `finished` event records for a stage that did not run because no changed path matched.
    public static let skippedVerdict = "skipped"

    /// `pr-review` as the config defines it: the built-in brief, with `[review.stage.pr-review]` (or `[pr_review]`)
    /// for its checklist and round cap.
    public static func prReview(_ config: Config) -> ReviewStage {
        ReviewStage(name: ReviewConfig.prReviewStage, config: config.review.prReview, events: .prReview)
    }

    /// The stage `name` of `review.stages`; `pr-review` also when it is not listed, as `workbench pr-review` runs it.
    public static func named(_ name: String, config: Config) -> ReviewStage? {
        if name == ReviewConfig.prReviewStage { return prReview(config) }
        guard config.review.stages.contains(name), let stage = config.review.stage(name) else { return nil }
        return ReviewStage(name: name, config: stage, events: .stage(name))
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
        // A heading inside a fenced example is part of the example, not the start or end of a section.
        var start: Int?
        var end = lines.count
        var fence: (char: Character, length: Int)?
        for (index, line) in lines.enumerated() {
            let wasFenced = fence != nil
            fence = PRBodyBuilder.nextFence(after: fence, line: line)
            if wasFenced || fence != nil { continue }
            if start == nil {
                if line.trimmingCharacters(in: .whitespaces) == "## Rubric" { start = index }
            } else if line.hasPrefix("# ") || line.hasPrefix("## ") {
                end = index
                break
            }
        }
        guard let start else { return Self.skillHeader + "\n\n" + text }
        let section = lines[(start + 1)..<end].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return section.isEmpty ? nil : section
    }

    /// What the stage's table asks for that this version does not do yet, said once per round rather than ignored.
    var notYetUsedWarning: String? {
        let keys = config.notYetUsed
        guard !keys.isEmpty else { return nil }
        return "the \(name) stage sets \(keys.joined(separator: ", ")), which this version does not use yet; "
            + "the built-in Codex review ran"
    }

    /// What `applies_to` decides from the pull request's `git diff --name-only -z` (nil when git could not run).
    enum Applies: Equatable {
        case run
        case skip
        /// The list is not whole, so no skip may be decided from it: the stage runs, and says why.
        case unknown(String)
    }

    func applies(listing result: GitResult?) -> Applies {
        guard !config.appliesTo.isEmpty else { return .run }
        guard let result, result.succeeded else {
            let why = result?.stderr.split(whereSeparator: \.isNewline).first.map(String.init) ?? "git failed"
            return .unknown("the changed files could not be read (\(why))")
        }
        guard !result.outputTruncated else {
            return .unknown("the list of changed files was cut at \(GitRunner.outputLimit >> 20) MiB")
        }
        return applies(to: result.stdout.split(separator: "\0").map(String.init).filter { !$0.isEmpty }) ? .run : .skip
    }

    /// Whether any of the files the pull request changes matches one of the stage's `applies_to` globs; an empty
    /// list applies to every change.
    func applies(to files: [String]) -> Bool {
        config.appliesTo.isEmpty || files.contains { file in config.appliesTo.contains { Self.glob($0, matches: file) } }
    }

    /// `**` matches any run of path segments (also none), `*` any run of characters within one segment, `?` one.
    /// Both levels fill a table over (pattern position, path position), so a match costs at most pattern length times
    /// path length: backtracking over partitions is exponential, and this runs with the thread's log held.
    static func glob(_ pattern: String, matches path: String) -> Bool {
        let pattern = pattern.split(separator: "/", omittingEmptySubsequences: false).map { Array($0) }
        let path = path.split(separator: "/", omittingEmptySubsequences: false).map { Array($0) }
        // rest[j]: the pattern segments after the current one match path segments j...
        var rest = [Bool](repeating: false, count: path.count + 1)
        rest[path.count] = true
        for segment in pattern.reversed() {
            var row = [Bool](repeating: false, count: path.count + 1)
            if segment == ["*", "*"] {
                var any = false
                for j in stride(from: path.count, through: 0, by: -1) {
                    any = any || rest[j]
                    row[j] = any
                }
            } else {
                for j in 0..<path.count where rest[j + 1] { row[j] = segmentMatches(segment, path[j]) }
            }
            rest = row
        }
        return rest[0]
    }

    private static func segmentMatches(_ pattern: [Character], _ text: [Character]) -> Bool {
        // reach[j]: the pattern read so far matches the first j characters of `text`.
        var reach = [Bool](repeating: false, count: text.count + 1)
        reach[0] = true
        for char in pattern {
            var next = [Bool](repeating: false, count: text.count + 1)
            switch char {
            case "*":
                var any = false
                for j in 0...text.count {
                    any = any || reach[j]
                    next[j] = any
                }
            case "?": for j in 0..<text.count where reach[j] { next[j + 1] = true }
            default: for j in 0..<text.count where reach[j] && text[j] == char { next[j + 1] = true }
            }
            guard next.contains(true) else { return false }
            reach = next
        }
        return reach[text.count]
    }
}
