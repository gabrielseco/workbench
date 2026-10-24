import Foundation

/// What a review round concluded. Only these two; anything else is a failed round, never a pass.
public enum PRReviewVerdict: String, Sendable, Equatable {
    case clean
    case fix
}

/// Everything the brief for the reviewer is built from. Text only: nothing here is read by Codex from the log.
/// A repository file a stage's `inputs` names, read from the pull request's checkout.
struct PRReviewFile: Sendable, Equatable {
    var path: String
    var text: String
}

struct PRReviewInput: Sendable, Equatable {
    var pr: Int
    var branch: String
    var base: String
    var headSHA: String
    /// The commit of `base` the diff is taken against, fetched from origin for this round.
    var baseSHA: String
    /// The goal file as the thread has it: the request and the numbered criteria the change was written against.
    var goal: String
    /// `AGENTS.md` (else `CLAUDE.md`) at the base, nil when the project has none or the config turns it off.
    var instructions: String?
    var checklist: String?
    var checklistPath: String?
    /// Where the diff of the pull request against its base is saved, for Codex to read.
    var diffPath: String
    var diffTruncated: Bool
    /// The stage's own rubric, from its `skill` or `prompt` file; nil for the built-in report instructions.
    var rubric: String?
    var rubricPath: String?
    /// The verifier's screenshots, absolute paths, each also attached to the Codex run as an image.
    var proof: [String] = []
    /// The files the stage's `inputs` names, in order, each already bounded.
    var files: [PRReviewFile] = []
}

/// The reviewer: an agent (Codex today), run read-only on the pull request's head in a throwaway checkout,
/// started by Workbench itself through `AgentRunner`. A project needs no script of its own (docs/plan/P5-review-loop.md).
public enum PRReview {
    /// One Codex run is ended, tree and all, after this long.
    public static let timeout: TimeInterval = 20 * 60
    /// Tries when Codex says its model is at capacity.
    public static let attempts = 3
    /// The dollar cap of a review on a provider that can enforce one (Claude); there is no config key for it.
    public static let claudeBudgetUSD: Decimal = 2
    public static let answerLimit = 256 << 10
    public static let transcriptLimit = 2 << 20
    public static let diffLimit = 400 << 10
    public static let goalLimit = 32 << 10
    public static let checklistLimit = 32 << 10
    /// Screenshots attached to one run, at most.
    public static let proofLimit = 20

    public static let cleanLine = "VERDICT: CLEAN"
    public static let fixLine = "VERDICT: FIX"

    /// What the reviewer is asked on the command line: the review text is in the brief file, so this only points at it.
    static func instruction(brief: String) -> String {
        "Read the review brief at \(brief) and follow it exactly. Do not run builds or tests, do not change "
            + "files and do not post anything anywhere."
    }

    /// The same pointer for a reviewer that cannot work inside the checkout: it runs in the round's folder, which holds
    /// the brief, the saved diff and the checkout, and may only read files there.
    static func instruction(brief: String, checkout: String) -> String {
        "Read the review brief at \(brief) and follow it exactly. Your working directory holds the brief, the diff and the "
            + "checkout of the head, which is the directory \(checkout); where the brief speaks of the working directory "
            + "it means that checkout. You can only read files. Do not change files and do not post anything anywhere."
    }

    /// The verdict is the last non-empty line, exactly. A missing line, a different last line, or both verdicts
    /// anywhere in the answer is no verdict: an answer that cannot say which it is must not count as clean.
    static func parseVerdict(_ answer: String) -> PRReviewVerdict? {
        let lines = answer.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let last = lines.last else { return nil }
        let markers = lines.filter { $0 == cleanLine || $0 == fixLine }
        guard markers.count == 1, markers[0] == last else { return nil }
        return last == cleanLine ? .clean : .fix
    }

    /// A fence longer than any run of backticks in `text`, so quoted content cannot close it.
    static func fenced(_ text: String) -> String {
        var longest = 0
        var run = 0
        for character in text {
            run = character == "`" ? run + 1 : 0
            longest = max(longest, run)
        }
        let fence = String(repeating: "`", count: max(3, longest + 1))
        return "\(fence)\n\(text.hasSuffix("\n") ? String(text.dropLast()) : text)\n\(fence)"
    }

    /// The `pr` of a round on a thread that has not opened one: the branch is reviewed where it is, locally.
    public static let noPullRequest = 0

    static func prompt(for input: PRReviewInput) -> String {
        var lines = [
            input.pr == noPullRequest ? "# Review the change on branch \(input.branch)" : "# Review pull request #\(input.pr)",
            "",
            "You are reviewing \(input.pr == noPullRequest ? "a change, not yet a pull request," : "a pull request") of this "
                + "repository. The working directory is a read-only checkout of "
                + "its head (\(input.headSHA)), branch \(input.branch), to be merged into \(input.base).",
            "Do not run builds or the test suite: read files and the diff only. Do not change files. Do not post "
                + "anything anywhere. `gh` and the network are not available to you.",
            "",
            "The change, as a diff against its base, is saved at \(input.diffPath). Read that file; it is the "
                + "whole change."
                + (input.diffTruncated ? " It was cut at \(diffLimit / 1024) KiB." : "")
                + " To read any part of the change again, run `git diff \(input.baseSHA)...\(input.headSHA)` in the checkout.",
            "",
            "## What the change was written against",
            "",
            "The goal file for this change; its acceptance criteria are the checklist for the review.",
            "",
            fenced(input.goal),
        ]
        if let instructions = input.instructions {
            lines += ["", "## Project instructions", "", fenced(instructions)]
        }
        if let checklist = input.checklist {
            lines += [
                "", "## This project's review checklist (\(input.checklistPath ?? "checklist"))", "", fenced(checklist),
            ]
        }
        for file in input.files {
            lines += [
                "", "## File: \(file.path)", "", "The stage's inputs name this file; read it as part of the review.", "",
                fenced(file.text),
            ]
        }
        if !input.proof.isEmpty {
            lines += [
                "", "## Proof", "",
                "Screenshots the project's verifier took of this change; each is attached to this run as an image.",
                "",
            ]
            // The size lets the reviewer name a capture that is clipped or too small to read.
            lines += input.proof.map { path in
                PNGSize.read(at: URL(fileURLWithPath: path)).map { "- \(path) (\($0.width) × \($0.height) px)" } ?? "- \(path)"
            }
        }
        if let rubric = input.rubric {
            lines += ["", "## Rubric (\(input.rubricPath ?? "rubric"))", "", "Review against this rubric.", "", fenced(rubric)]
        } else {
            lines += [
                "",
                "## Report",
                "",
                "Most severe first, each finding with a concrete failure scenario (inputs or state, then the wrong "
                    + "result), and the file and line.",
                "1. Each acceptance criterion: holds / does not hold / cannot tell. A test existing is not enough: "
                    + "say whether it would fail without the behaviour.",
                "2. Defects the change introduces: correctness, security, reliability, a missing test for a failure case.",
                "3. Anything the goal asked for that is missing, and anything the change does that was not asked for.",
                "Keep it under 90 lines and leave out anything that is not a finding.",
            ]
        }
        lines += [
            "",
            "## Last line",
            "",
            "End your answer with exactly one final line and nothing after it:",
            "- `\(cleanLine)` when nothing needs fixing before merge.",
            "- `\(fixLine)` when at least one finding holds and should be fixed.",
            "",
        ]
        return lines.joined(separator: "\n")
    }
}

public enum PRReviewRefusal: Error, Equatable, Sendable, CustomStringConvertible {
    case noPullRequest
    case capReached(pr: Int, rounds: Int, max: Int)
    case alreadyReviewed(round: Int)
    case originUnreadable(String)
    case branchGone(String)
    case goalUnreadable(String)
    case busy
    case unknownStage(String, listed: [String])
    case stageCapReached(stage: String, pr: Int, rounds: Int, max: Int)
    case pullRequestUnreadable(Int, String)
    case notReviewable(Int, String)

    public var description: String {
        switch self {
        case .pullRequestUnreadable(let number, let why):
            "pull request #\(number) could not be read with `gh`: \(why)"
        case .notReviewable(let number, let why):
            "pull request #\(number) is not one `workbench pr-review --pr` reviews: \(why)"
        case .unknownStage(let name, let listed):
            "there is no review stage '\(name)' in review.stages (it lists \(listed.joined(separator: ", "))). "
                + "Add it to [review] stages and give it a [review.stage.\(name)] table."
        case .stageCapReached(let stage, let pr, let rounds, let max):
            "the \(stage) stage reviewed pull request #\(pr) \(rounds) time\(rounds == 1 ? "" : "s") already "
                + "(max_rounds is \(max)). Read the last findings with `workbench review`; raise `max_rounds` in "
                + "[review.stage.\(stage)] to allow more."
        case .noPullRequest:
            "this thread has no recorded pull request. Run `workbench ship` first; the review is of that pull request."
        case .capReached(let pr, let rounds, let max):
            "pull request #\(pr) was reviewed \(rounds) time\(rounds == 1 ? "" : "s") already (max_rounds is \(max)). "
                + "Read the last findings with `workbench review`; raise `max_rounds` in [pr_review] to allow more."
        case .alreadyReviewed(let round):
            "round \(round) reviewed the branch as it is now (`workbench review` shows it). Pass --again to ask once more."
        case .originUnreadable(let why): "origin could not be read: \(why)"
        case .branchGone(let branch):
            "origin no longer has \(branch). The pull request may be merged or closed, so there is nothing to review."
        case .goalUnreadable(let why): "the goal could not be read: \(why)"
        case .busy:
            "another command is using this thread (a run, a judge or another pr-review); try again when it ends."
        }
    }
}

/// What a round came to. A failed round is a result, not a thrown error: it is on record, with the reason.
public struct PRReviewResult: Sendable, Equatable {
    public var round: Int
    public var pr: Int
    public var maxRounds: Int
    public var headSHA: String
    public var verdict: PRReviewVerdict?
    /// Why there is no verdict.
    public var failure: String?
    /// Relative to the thread's directory.
    public var findingsPath: String?
    /// The reviewer's answer, as stored.
    public var findings: String?
    public var warnings: [String]
    /// Why the stage did not run: its `applies_to` matches nothing the pull request changes. Never a pass.
    public var skipped: String?
    /// What the reviewer's provider reported it cost; nil when it reports none, which is not 0.
    public var costUSD: Double?
}
