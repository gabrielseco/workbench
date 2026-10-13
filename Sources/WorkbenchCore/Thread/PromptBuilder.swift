import Foundation

/// Builds what Claude is told. The goal is the only input to the first prompt (docs/spec/goal-file.md).
public enum PromptBuilder {
    /// Shown above the project's instructions file, which is included whole and unmodified.
    public static let instructionsIntro =
        "These are the project's instructions for anyone working in this repository. Where they describe "
        + "pushing, opening or merging pull requests, Workbench does that after your work is reviewed: "
        + "commit in this worktree and stop there."

    public static func firstPrompt(
        goal: Goal, checkCommand: String?, instructions: ProjectInstructions? = nil
    ) -> String {
        var out = "# \(goal.title)\n\n"
        out += "## Request\n\n\(goal.request)\n\n"
        out += "## Criteria\n\nThe work is done when every criterion holds. Each says how it will be shown.\n\n"
        for criterion in goal.criteria {
            out += "- [\(criterion.id)] \(criterion.text)\n  - proof: \(criterion.proof)\n"
        }
        if !goal.outOfScope.isEmpty {
            out += "\n## Out of scope\n\nDo not do any of these:\n\n"
            for item in goal.outOfScope { out += "- \(item)\n" }
        }
        if let instructions {
            out += "\n## Project instructions\n\n\(instructionsIntro)\n\n\(instructions.text)\n"
        }
        if let check = checkCommand {
            out += """

                ## Checking your work

                While you work, check what you changed with the narrowest command you are allowed to run \
                (one test target or file) instead of the full check each time. The full check is \
                `\(check)`: Workbench runs it itself when you finish, and that run is what the reviewer \
                sees. Run it yourself at most once, at the end, to be sure.

                """
        }
        out += "\nWork in the current directory. When you finish, say which criteria you believe hold and why.\n"
        return out
    }

    public static func followUpPrompt(feedback: String) -> String {
        "The reviewer sent this back with feedback:\n\n\(feedback)\n\n"
            + "Address it, keeping to the original criteria and out of scope. "
            + "When you finish, say which criteria you believe hold and why.\n"
    }

    /// Appended to Claude Code's own system prompt (`--append-system-prompt`).
    public static func rules(checkCommand: String?) -> String {
        var out = """
            You are working in an isolated git worktree for one task. Stay inside the current directory. \
            Do not push, merge, publish or change anything outside it. Commit your work with clear messages \
            when a logical step is complete. If a tool is denied, do not retry it or look for a way around \
            it: say what you needed and continue with what is allowed.
            """
        if let check = checkCommand {
            out += " The project's full check is `\(check)`; run it exactly as written, variations of it are denied."
        }
        return out
    }
}
