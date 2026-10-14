import Foundation

/// Names that end up in directory names and git arguments. One definition, used by the goal parser and
/// the worktree manager, so what a goal accepts is exactly what the worktree layer will accept.
enum SafeNames {
    /// A thread id: used as `threads/<id>`, `worktrees/<id>` and `workbench/<id>`.
    static func isThreadID(_ s: String) -> Bool {
        s.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$"#, options: .regularExpression) != nil
            && !s.hasSuffix(".lock") && !s.hasSuffix(".")
    }

    /// A model name or alias that goes to `--model`: no leading `-`, no whitespace.
    static func isModelName(_ s: String) -> Bool {
        s.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:\[\]-]*$"#, options: .regularExpression) != nil
    }

    /// A branch or ref name we are willing to pass to git: no leading `-`, no `..`, no whitespace.
    static func isBranchName(_ s: String) -> Bool {
        s.range(of: #"^[A-Za-z0-9._/][A-Za-z0-9._/-]*$"#, options: .regularExpression) != nil
            && !s.contains("..") && !s.hasSuffix("/") && !s.hasSuffix(".lock") && !s.contains("//")
    }
}
