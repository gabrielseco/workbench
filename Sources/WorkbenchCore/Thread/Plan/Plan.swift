import Foundation

/// Everything the plan turn is told, assembled by Workbench. The only other thing it can read is the repository
/// at the base commit, in its working directory.
public struct PlanInput: Sendable, Equatable {
    public var goal: Goal
    public var baseCommit: String
    public var instructions: ProjectInstructions?
}

/// The request for a plan and the reading of its answer. Pure: no process, no files.
public enum Plan {
    public static let budgetUSD: Decimal = 1
    public static let timeout: TimeInterval = 600
    /// The most plan text kept; past it the text is cut and says so.
    public static let textLimit = 16 * 1024
    public static let cutMarker = "\n\n[the plan was cut here at \(textLimit) bytes]\n"

    public static func prompt(for input: PlanInput) -> String {
        let goal = input.goal
        var out = "# Plan the work: \(goal.title)\n\n"
        out += """
            You are planning a change to the repository in your working directory, as it is at commit \
            `\(input.baseCommit.prefix(12))`. Another model will carry the plan out; you cannot edit anything and \
            should not try. Read what you need with the tools you have, then answer with the plan only.

            ## Request

            \(goal.request)

            ## Criteria

            The work is done when every criterion holds. Each says how it will be shown.


            """
        for criterion in goal.criteria {
            out += "- [\(criterion.id)] \(criterion.text)\n  - proof: \(criterion.proof)\n"
        }
        if !goal.outOfScope.isEmpty {
            out += "\n## Out of scope\n\nThe plan must not include any of these:\n\n"
            for item in goal.outOfScope { out += "- \(item)\n" }
        }
        if let instructions = input.instructions {
            out += "\n## Project instructions\n\n\(PromptBuilder.instructionsIntro)\n\n\(instructions.text)\n"
        }
        out += """

            ## What to write

            A plan in Markdown, under about 600 words, with these sections:

            - **Approach**: how the change is made, in a few sentences.
            - **Files**: the files to change or add, each with one line on what changes.
            - **Order**: the steps, in the order to do them, naming the tests to write or run.
            - **Risks**: what could go wrong or is easy to miss, including anything a criterion implies that the \
            request does not say.

            The criteria and the out-of-scope list above are the contract; the plan serves them. Do not restate \
            the request, do not write the code, and do not ask questions: where something is unclear, say what \
            you assumed.

            """
        return out
    }

    /// The text to store: trimmed, without machine paths or credentials, cut at `textLimit` bytes. Nil when
    /// nothing is left.
    public static func stored(from raw: String) -> (text: String, truncated: Bool)? {
        let cleaned = ThreadService.withoutCredentials(PRBodyBuilder.scrub(raw))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        guard cleaned.utf8.count > textLimit else { return (cleaned + "\n", false) }
        // Cut on a character boundary: `prefix` of the UTF-8 view can end inside a scalar, which decodes as U+FFFD.
        var cut = String(decoding: cleaned.utf8.prefix(textLimit), as: UTF8.self)
        while cut.unicodeScalars.last == "\u{FFFD}" { cut.unicodeScalars.removeLast() }
        return (cut + cutMarker, true)
    }

    /// Closes a plan whose process died and ends what it left behind: a `claude` running in the plan folder and the
    /// checkout. Run by every command that opens the log, so the next one of any kind finds it closed.
    /// Returns whether there was one.
    @discardableResult
    static func recoverOrphan(log: EventLogWriter, folder: URL, repoRoot: URL, git: GitRunner) async throws -> Bool {
        guard await log.hasOpenPlan else { return false }
        OrphanSweeper.sweep(inside: folder)
        await WorktreeManager(repoRoot: repoRoot, git: git).removeDetached(at: folder.appendingPathComponent("checkout"))
        try await log.recoverOrphanedPlan()
        return true
    }

    @discardableResult
    static func recoverOrphan(log: EventLogWriter, project: Project, threadID: String, git: GitRunner) async throws -> Bool {
        let folder = project.threadDirectory(threadID).appendingPathComponent("plan")
        return try await recoverOrphan(log: log, folder: folder, repoRoot: project.root, git: git)
    }

    public static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
