import Foundation

/// The rules for one simple command. Each verdict says how risky the command is and, when the command is
/// safe and common, how many leading words make a narrow prefix to grant (`gh pr view` for `gh pr view 12`).
private struct Verdict {
    var level: DeniedCommandAssessment.Level
    var reason: String?
    var prefixWords: Int?

    static let safe = Verdict(level: .safe, reason: nil, prefixWords: nil)
    static func safe(prefix: Int) -> Verdict {
        Verdict(level: .safe, reason: nil, prefixWords: prefix)
    }
    static func caution(_ reason: String) -> Verdict {
        Verdict(level: .caution, reason: reason, prefixWords: nil)
    }
    static func unsafe(_ reason: String) -> Verdict {
        Verdict(level: .unsafe, reason: reason, prefixWords: nil)
    }
}

extension DeniedCommandClassifier {
    static func assess(_ segment: ShellSplit.Segment) -> DeniedCommandAssessment.Part {
        var words = segment.words
        var reasons: [String] = []
        var level = DeniedCommandAssessment.Level.safe
        func note(_ verdict: Verdict) {
            level = max(level, verdict.level)
            if let reason = verdict.reason { reasons.append(reason) }
        }

        // `do gh pr view $n` is the command `gh pr view $n` inside a loop; the loop itself is not a command.
        while let first = words.first, ["do", "then", "else", "elif", "!", "{"].contains(first) {
            words.removeFirst()
        }
        if let first = words.first, loopWords.contains(first) {
            note(.caution("a shell loop or condition; ask for one command at a time"))
            words = []
        }
        let assignments = words.prefix {
            $0.range(of: #"^[A-Za-z_][A-Za-z0-9_]*="#, options: .regularExpression) != nil
        }
        words.removeFirst(assignments.count)
        if !assignments.isEmpty {
            note(.caution("starts with an environment variable, which a prefix rule does not match"))
        }

        var prefixWords: Int?
        if let command = words.first {
            let verdict = self.verdict(for: words, afterPipe: segment.joinedBy == "|")
            note(verdict)
            prefixWords = verdict.prefixWords
            let pathArgs = words.dropFirst().contains { escapesWorktree(optionValue($0)) }
            if verdict.level == .safe, pathArgs, !pathLooseCommands.contains(command) {
                note(.caution("names a path outside the worktree"))
            }
        }
        for target in segment.redirects {
            note(
                escapesWorktree(target)
                    ? .unsafe("writes \(target), outside the worktree")
                    : .caution("writes a file; the file tools do that"))
        }
        let beforeFlags = level
        if segment.hasSubstitution {
            note(.caution("runs another command inside it ($(…) or backticks)"))
        }
        if segment.hasVariable { note(.caution("uses a variable, so what it runs is not fixed")) }
        if segment.hasHeredoc { note(.caution("writes a file with a heredoc; the file tools do that")) }
        if words.isEmpty, level == .safe { note(.caution("no command")) }

        return DeniedCommandAssessment.Part(
            command: segment.raw, level: level, reasons: reasons,
            pattern: pattern(for: segment, words: words, baseLevel: beforeFlags, prefixWords: prefixWords)
        )
    }

    /// `Bash(prefix:*)` for a safe command with a known narrow prefix, `Bash(command)` otherwise; nil when the
    /// text is not fixed (substitutions, redirects) or cannot sit inside the parentheses. A variable in the
    /// arguments of a safe prefixed command (`gh pr view $n`) still gets the prefix, never the text with the variable.
    private static func pattern(
        for segment: ShellSplit.Segment, words: [String], baseLevel: DeniedCommandAssessment.Level,
        prefixWords: Int?
    ) -> String? {
        if words.isEmpty || segment.hasSubstitution || segment.hasHeredoc || !segment.redirects.isEmpty {
            return nil
        }
        let prefix = prefixWords.flatMap { $0 <= words.count ? Array(words.prefix($0)) : nil }
        if baseLevel == .safe, let prefix, !prefix.contains(where: { $0.contains("$") }) {
            return "Bash(\(prefix.joined(separator: " ")):*)"
        }
        if segment.hasVariable || segment.raw.contains("(") || segment.raw.contains(")") { return nil }
        return "Bash(\(segment.raw))"
    }

    private static let loopWords: Set<String> = [
        "for", "while", "until", "if", "case", "done", "fi", "esac", "}", "function",
    ]

    /// The part of an argument that may be a path: the value of `--output=/x` or `-o/x`, or the word itself.
    private static func optionValue(_ arg: String) -> String {
        guard arg.hasPrefix("-") else { return arg }
        if let equals = arg.firstIndex(of: "=") { return String(arg[arg.index(after: equals)...]) }
        return arg.hasPrefix("--") || arg.count <= 2 ? "" : String(arg.dropFirst(2))
    }

    /// Commands whose arguments are not paths, so an absolute-looking word is not a path.
    private static let pathLooseCommands: Set<String> = ["echo", "printf", "grep", "rg", "test", "["]

    private static let readers: Set<String> = [
        "ls", "cat", "head", "tail", "wc", "grep", "rg", "echo", "printf", "pwd", "test", "[", "true",
        "false", "diff",
        "sort", "uniq", "cut", "tr", "basename", "dirname", "stat", "file", "which", "shasum",
        "shellcheck",
    ]
    private static let neverRun: Set<String> = [
        "sudo", "su", "eval", "dd", "mkfs", "ssh", "scp", "nc", "ncat", "doas",
    ]
    private static let interpreters: Set<String> = [
        "python", "python3", "node", "ruby", "perl", "bash", "sh", "zsh", "osascript", "php",
    ]
    private static let shells: Set<String> = [
        "sh", "bash", "zsh", "eval", "python", "python3", "node", "ruby", "perl",
    ]

    private static func verdict(for words: [String], afterPipe: Bool) -> Verdict {
        let command = words[0]
        let args = Array(words.dropFirst())
        if afterPipe, shells.contains(command) {
            return .unsafe("pipes into \(command), which runs whatever it is given")
        }
        if neverRun.contains(command) { return .unsafe("\(command) is never granted") }
        switch command {
        case "git": return gitVerdict(args)
        case "gh": return ghVerdict(args)
        case "chmod": return chmodVerdict(args)
        case "rm": return rmVerdict(args)
        case "mkdir", "touch":
            return args.contains(where: escapesWorktree) ? .unsafe("writes outside the worktree") : .safe
        case "cp", "mv":
            return args.contains(where: escapesWorktree)
                ? .unsafe("writes outside the worktree") : .caution("\(command) can overwrite a file")
        case "ln":
            return args.contains(where: escapesWorktree)
                ? .caution("links to a path outside this directory") : .safe
        case "find": return findVerdict(args)
        case "sed":
            return sedVerdict(args)
        case "swift":
            return ["build", "test"].contains(args.first ?? "")
                ? .safe(prefix: 2) : .caution("swift \(args.first ?? "") is not a build or test")
        case "swiftlint":
            return args.first == "lint"
                ? .safe(prefix: 2) : .caution("swiftlint \(args.first ?? "") is not a lint")
        case "shellcheck": return .safe(prefix: 1)
        case "command": return args.first == "-v" ? .safe : .caution("command runs another command")
        case "curl", "wget": return .caution("reaches the network")
        case "xargs", "env", "nohup", "time": return .caution("\(command) runs another command")
        default: break
        }
        if interpreters.contains(command) {
            let syntaxCheck = ["bash", "sh", "zsh"].contains(command) && args.first == "-n" && args.count == 2
            // No prefix: `bash -n:*` would also match `bash -n +n -c …`, which runs the command.
            if syntaxCheck, !escapesWorktree(args[1]) { return .safe }
            return .caution("\(command) can run anything")
        }
        if readers.contains(command) { return readerVerdict(command, args) }
        if command.contains("/") {
            return escapesWorktree(command)
                ? .unsafe("runs a program outside the worktree")
                : .caution("runs a script from the worktree")
        }
        return .caution("\(command) is not a command Workbench knows")
    }

    /// `sed -n 3,9p` prints lines. Any other script can write (`w file`), run (`e`) or edit in place (`-i`).
    private static func sedVerdict(_ args: [String]) -> Verdict {
        let printsLines =
            args.first == "-n" && args.count >= 2
            && args[1].range(of: #"^[0-9$]+(,[0-9$]+)?p$"#, options: .regularExpression) != nil
        return printsLines ? .safe : .caution("sed can write files, run commands or edit in place")
    }

    /// A command that only reads, unless an option or a second file name makes it write.
    private static func readerVerdict(_ command: String, _ args: [String]) -> Verdict {
        let writesOutput = command == "sort" && args.contains { $0.hasPrefix("-o") || $0.hasPrefix("--output") }
        let uniqOperands = command == "uniq" ? args.filter { !$0.hasPrefix("-") } : []
        let uniqOutput = uniqOperands.count > 1
        let outside =
            writesOutput && args.contains(where: { escapesWorktree(optionValue($0)) })
            || uniqOutput && escapesWorktree(uniqOperands[1])
        if outside { return .unsafe("\(command) writes a file outside the worktree") }
        return writesOutput || uniqOutput ? .caution("\(command) writes the file it is given") : .safe
    }

    private static let safeGit: Set<String> = [
        "status", "diff", "log", "show", "add", "commit", "rev-parse", "ls-files", "blame", "grep",
        "shortlog", "describe",
    ]

    private static func gitVerdict(_ args: [String]) -> Verdict {
        guard let sub = args.first(where: { !$0.hasPrefix("-") }), args.first == sub else {
            return .caution("git with options before its command")
        }
        let rest = Array(args.dropFirst())
        switch sub {
        case _ where safeGit.contains(sub): return .safe(prefix: 2)
        case "update-index":
            let modes = rest.filter { $0.hasPrefix("--chmod=") }
            let paths = rest.filter { !$0.hasPrefix("-") }
            let onlyExec = !modes.isEmpty && modes.allSatisfy { $0 == "--chmod=+x" || $0 == "--chmod=-x" }
            return onlyExec && rest.allSatisfy { $0.hasPrefix("--chmod=") || !escapesWorktree($0) }
                && !paths.isEmpty
                ? .safe : .caution("update-index changes the index")
        case "push": return pushVerdict(rest)
        case "reset":
            return rest.contains("--hard")
                ? .unsafe("git reset --hard discards work") : .caution("git reset moves the branch")
        case "clean": return .unsafe("git clean deletes untracked files")
        case "fetch": return .caution("reaches the network")
        default: return .caution("git \(sub) changes the repository")
        }
    }

    private static func pushVerdict(_ args: [String]) -> Verdict {
        let force = args.contains {
            ["--force", "-f", "--delete", "-d", "--mirror", "--all", "--prune"].contains($0)
                || $0.hasPrefix("--force")
        }
        let operands = args.filter { !$0.hasPrefix("-") }
        if let remote = operands.first, remote != "origin" {
            return .unsafe("git push to \(remote), a remote other than origin")
        }
        let refs = operands.dropFirst()
        let protected = refs.contains { ref in
            ref.hasPrefix("+") || ref.hasPrefix(":")
                || ["main", "master", "develop", "HEAD:main", "HEAD:master"].contains(ref)
                || ref.hasSuffix(":main") || ref.hasSuffix(":master")
        }
        if force || protected {
            return .unsafe("git push that forces, deletes or targets a protected branch")
        }
        return .caution("git push publishes work; `ship` does that")
    }

    private static func ghVerdict(_ args: [String]) -> Verdict {
        let words = args.filter { !$0.hasPrefix("-") }
        let key = words.prefix(2).joined(separator: " ")
        if [
            "pr view", "pr list", "pr checks", "pr diff", "pr status", "issue view", "issue list",
            "run view", "run list", "repo view",
        ]
        .contains(key) {
            return .safe(prefix: 3)
        }
        switch words.first {
        case "api":
            let writes = ghApiWrites(args)
            return writes ? .unsafe("gh api that writes") : .caution("gh api reaches GitHub")
        default:
            if key == "pr merge" || key.hasSuffix(" delete") {
                return .unsafe("gh \(key) cannot be undone")
            }
            return .caution("gh \(key) changes something on GitHub")
        }
    }

    /// A `gh api` call that sends data or uses a method other than GET, whether the option and its value are
    /// two words (`-X POST`) or one (`-XPOST`, `--method=POST`, `-fkey=v`).
    private static func ghApiWrites(_ args: [String]) -> Bool {
        for (index, arg) in args.enumerated() {
            if ["-f", "-F", "--field", "--raw-field", "--input"].contains(arg) { return true }
            if arg.hasPrefix("--field=") || arg.hasPrefix("--raw-field=") || arg.hasPrefix("--input=") { return true }
            if arg.hasPrefix("-f") && !arg.hasPrefix("--") || arg.hasPrefix("-F") && !arg.hasPrefix("--") { return true }
            var method: String?
            if arg == "-X" || arg == "--method" { method = args[safe: index + 1] }
            if arg.hasPrefix("--method=") { method = String(arg.dropFirst("--method=".count)) }
            if arg.hasPrefix("-X"), arg.count > 2 { method = String(arg.dropFirst(2)) }
            if let method, method.uppercased() != "GET" { return true }
        }
        return false
    }

    private static func chmodVerdict(_ args: [String]) -> Verdict {
        let paths = args.filter { !$0.hasPrefix("-") && !$0.hasPrefix("+") }
        if args.contains(where: { $0 == "-R" || $0 == "--recursive" }) {
            return .unsafe("recursive chmod")
        }
        if paths.contains(where: escapesWorktree) {
            return .unsafe("chmod of a path outside the worktree")
        }
        return args.contains("+x") || args.contains("-x")
            ? (paths.isEmpty ? .caution("chmod without a path") : .safe)
            : .caution("chmod changes more than the executable bit")
    }

    private static func rmVerdict(_ args: [String]) -> Verdict {
        if args.contains(where: escapesWorktree) { return .unsafe("rm of a path outside the worktree") }
        if args.contains(where: { $0.hasPrefix("-") && ($0.contains("r") || $0.contains("R")) }) {
            return .unsafe("recursive rm")
        }
        return .caution("rm deletes a file")
    }

    private static func findVerdict(_ args: [String]) -> Verdict {
        if args.contains("-delete") { return .unsafe("find -delete") }
        if args.contains(where: { $0.hasPrefix("-fprint") || $0.hasPrefix("-fls") }) {
            return .caution("find writes the file it is given")
        }
        if args.contains(where: { ["-exec", "-execdir", "-ok"].contains($0) }) {
            return .caution("find runs a command on each match")
        }
        return .safe
    }
}

extension Array {
    fileprivate subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
