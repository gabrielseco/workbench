import Foundation

/// Per-command help. It is cut from `workbenchUsage` (a command's entries are its lines indented by two
/// spaces, and the deeper lines that follow them), so what a command takes is written once. What is added
/// here is only what the usage block leaves out: what a command changes and one example.
enum Help {
    struct Entry: Equatable {
        /// The leading words of the synopsis: `["plan", "show"]`, `["grant"]`.
        var words: [String]
        /// The synopsis alone, up to the gap before the description: `plan show [id]`.
        var synopsis: String
        /// The entry as it reads in the usage block, dedented by two spaces.
        var lines: [String]
    }

    /// What the usage block does not say. Keyed by the command's first word.
    struct Extra {
        var changes: String
        var example: String
    }

    static let extras: [String: Extra] = [
        "new": Extra(
            changes: "creates a directory with a git repository and .workbench/config.toml; refuses a non-empty target",
            example: "workbench new my-app --in ~/projects"),
        "init": Extra(
            changes: "writes .workbench/config.toml in this repository; keeps an existing one",
            example: "workbench init"),
        "config": Extra(changes: "nothing; read-only", example: "workbench config"),
        "doctor": Extra(
            changes:
                "nothing in the project or a thread: runs the declared setup, check and "
                + "verify in a throwaway worktree that it removes",
            example: "workbench doctor --base main"),
        "goal": Extra(
            changes:
                "goal new: creates a thread and a draft goal; goal draft: runs the goal agent read-only and creates a "
                + "draft thread (or, with --replace, rewrites an existing goal and returns it to draft); goal approve: "
                + "records the approval in the thread's log",
            example: "workbench goal new add-retry && workbench goal approve"),
        "run": Extra(
            changes: "creates the thread's worktree and branch, runs Claude and the project's check there, appends to the log",
            example: "workbench run"),
        "send-back": Extra(
            changes:
                "runs another turn in the thread's worktree with your note and the "
                + "failed check's output; appends to the log",
            example: "workbench send-back \"also handle the empty list\""),
        "stop": Extra(
            changes: "asks the live run to stop; it records the turn as stopped itself",
            example: "workbench stop"),
        "log": Extra(
            changes: "nothing; read-only", example: "workbench log -f   or   workbench log --transcript --turn 1 | jq ."),
        "status": Extra(
            changes: "nothing in the thread; --fetch updates origin/<base> in your repository",
            example: "workbench status --all --json"),
        "review": Extra(
            changes: "nothing in the thread; --fetch updates origin/<base> in your repository",
            example: "workbench review --json"),
        "next": Extra(
            changes: "nothing; read-only, derived from the thread's log and its changed files",
            example: "workbench next"),
        "open": Extra(
            changes: "nothing in the thread or its worktree; --diff builds a folder of its own under the thread, "
                + "replaced each time; starts the editor (or, with --print, nothing)",
            example: "workbench open --editor cursor   or   workbench open --diff   or   cd \"$(workbench open --print)\""),
        "grant": Extra(
            changes:
                "the list: nothing; a decision (--once, --thread, --never): appends "
                + "it to the thread's log, not to the config",
            example: "workbench grant && workbench grant 1 --once"),
        "judge": Extra(
            changes: "runs a second, read-only Claude; appends its verdict and cost to the log",
            example: "workbench judge --model sonnet"),
        "verifier": Extra(
            changes:
                "runs a separate Claude on the project's skill in the thread's worktree; adds its screenshots "
                + "to the turn's proof folder; appends verifier.started and verifier.ended with the cost to the log",
            example: "workbench verifier --again"),
        "plan": Extra(
            changes:
                "plan: runs a read-only agent ([agents.plan]) and saves the plan under plans/ in the thread folder; "
                + "plan show: nothing; plan edit: copies or applies plans/draft.md",
            example: "workbench plan && workbench plan show"),
        "pr-review": Extra(
            changes: "runs Codex read-only on a pull request in a throwaway checkout; records the round; posts nothing",
            example: "workbench pr-review --pr 12"),
        "review-stage": Extra(
            changes: "runs one configured review stage read-only; records the round",
            example: "workbench review-stage design"),
        "accept": Extra(
            changes:
                "commits the work on its branch and ends the thread; does not push; -m is used only when "
                + "accept commits",
            example: "workbench accept -m \"feat: add retry\" --yes"),
        "ship": Extra(
            changes: "pushes the accepted branch and opens its pull request after asking; never merges",
            example: "workbench ship --yes --watch"),
        "clean": Extra(
            changes:
                "removes the worktree and local branch of shipped threads whose pull "
                + "request is merged; a dry run without --yes",
            example: "workbench clean --yes"),
        "discard": Extra(
            changes: "deletes the thread's worktree and branch and keeps the log; asks first",
            example: "workbench discard --yes"),
        "abandon": Extra(
            changes:
                "ends the thread, saves uncommitted changes as abandon.patch in the thread "
                + "folder, removes the worktree, keeps the branch",
            example: "workbench abandon"),
        "task": Extra(
            changes:
                "task new: creates .workbench/tasks/<name>/ with task.md and pending.sh; task list and task log: nothing; "
                + "read-only; task approve: appends task.approved to the task's own run log "
                + "(.workbench/tasks/<name>/runs.jsonl); task timer: install writes the launcher under "
                + "~/.workbench/timers/ and the agent in ~/Library/LaunchAgents and loads it with launchctl, remove undoes "
                + "that, status reads; task run and task tick: append task.run.started and task.run.ended there and, with "
                + "fix: pr, create a thread, run Claude and the check in its worktree, accept it and push its branch to "
                + "open a pull request",
            example: "workbench task new bump-countries --input countries.txt   or   workbench task run bump-countries"),
        "version": Extra(changes: "nothing; read-only", example: "workbench version"),
    ]

    /// The commands whose output `--json` turns into JSON (main.swift refuses it elsewhere).
    static let jsonCommands: Set<String> = ["status", "review", "log", "grant", "doctor"]

    static let exitLine =
        "exit: 0 done; 2 usage; 6 refused (nothing was changed); 7 not found; the rest per command in docs/spec/exit-codes.md"

    static func entries(in usage: String = workbenchUsage) -> [Entry] {
        var found: [Entry] = []
        var current: Entry?
        func close() {
            if let entry = current { found.append(entry) }
            current = nil
        }
        for raw in usage.components(separatedBy: "\n") {
            let indent = raw.prefix(while: { $0 == " " }).count
            let body = raw.trimmingCharacters(in: .whitespaces)
            if body.isEmpty { close(); continue }
            if indent == 2, !body.hasPrefix("--") {
                close()
                let parts = body.components(separatedBy: "  ")
                var synopsis = parts[0].trimmingCharacters(in: .whitespaces)
                // `run` and `goal new` list their flags in the description on the same line.
                let described = parts.dropFirst().joined(separator: "  ")
                for flags in described.matches(of: /\[--?[^\[\]]*\]/) { synopsis += " " + flags.output }
                current = Entry(words: words(of: synopsis), synopsis: synopsis, lines: [String(raw.dropFirst(2))])
            } else if indent > 2, current != nil {
                // A synopsis that wraps (`ship`) continues on a line of its own that starts with `[`.
                if current?.lines.count == 1, body.hasPrefix("["), current?.lines[0].contains("  ") == false {
                    current?.synopsis += " " + body
                }
                current?.lines.append(String(raw.dropFirst(2)))
            } else {
                close()
            }
        }
        close()
        return found
    }

    /// The words before the first argument: `goal new <name>` is `goal`, `new`; `pr-review --pr <n>` is `pr-review`.
    private static func words(of synopsis: String) -> [String] {
        var words: [String] = []
        for token in synopsis.split(separator: " ") {
            if let first = token.first, "[<-\"".contains(first) { break }
            words.append(String(token))
        }
        return words
    }

    /// The command names in the usage block, in order, each once.
    static func commandNames(_ entries: [Entry] = entries()) -> [String] {
        var seen: Set<String> = []
        return entries.compactMap { $0.words.first }.filter { seen.insert($0).inserted }
    }

    /// The entries a query selects: every entry whose leading words start with the query's words.
    static func matching(_ query: [String], in entries: [Entry] = entries()) -> [Entry] {
        entries.filter { $0.words.starts(with: query) }
    }

    /// The help for `query` (`["plan", "show"]`), nil when no command matches.
    static func text(for query: [String]) -> String? {
        let all = entries()
        let selected = matching(query, in: all)
        guard let name = query.first, !selected.isEmpty else { return nil }
        var lines = ["workbench \(name)", ""]
        lines += selected.flatMap(\.lines)
        lines.append("")
        if let extra = extras[name] {
            lines.append("changes: \(extra.changes)")
            lines.append("example: \(extra.example)")
        }
        lines.append(
            jsonCommands.contains(name)
                ? "--json: yes, machine-readable output (errors too)" : "--json: no")
        lines.append(exitLine)
        return lines.joined(separator: "\n")
    }

    /// The options that take a value, read from the usage block (`--model <name>`, `--feedback "<text>"`) so a new one
    /// is covered without a second list, and joined with the ones `main.swift` already knows.
    static func valueOptions(adding known: Set<String>) -> Set<String> {
        var found = known
        let pattern = #"(--?[A-Za-z][A-Za-z-]*)\s+"?<"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let text = workbenchUsage
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let range = Range(match.range(at: 1), in: text) { found.insert(String(text[range])) }
            }
        }
        return found
    }

    /// What `workbench help ...` or `workbench <command> ... --help` asks for, nil when it is neither.
    /// An option's value that reads `--help` is a value, not the request.
    static func request(_ arguments: [String], valueOptions: Set<String>) -> [String]? {
        guard let first = arguments.first else { return nil }
        if first == "help" {
            let words = Array(arguments.dropFirst().filter { !$0.hasPrefix("-") })
            return words.isEmpty ? nil : words
        }
        guard commandNames().contains(first) else { return nil }
        // `log -f` follows; everywhere else `-f` takes a value.
        let all = valueOptions
        let values = first == "log" ? all.subtracting(["-f"]) : all
        // Walk the arguments and skip each option's value: in `run --feedback --model --help`, `--model` is the value
        // and the last word asks for help.
        var asked = false
        var index = 1
        while index < arguments.count {
            if values.contains(arguments[index]) {
                index += 2
            } else {
                if ["--help", "-h"].contains(arguments[index]) { asked = true }
                index += 1
            }
        }
        guard asked else { return nil }
        // `plan show --help` is the help for `plan show`: keep the words that still select an entry.
        var query = [first]
        let known = entries()
        for word in arguments.dropFirst() where !word.hasPrefix("-") {
            guard !matching(query + [word], in: known).isEmpty else { break }
            query.append(word)
        }
        return query
    }

    /// A usage error's message with the command's synopsis, still one line: the spec keeps stderr to one record.
    static func withSynopsis(_ message: String, arguments: [String]) -> String {
        guard let first = arguments.first, commandNames().contains(first) else { return message }
        let synopses = matching([first]).map(\.synopsis)
        var text = message
        if !message.hasPrefix("usage:") { text += "; usage: " + synopses.joined(separator: " | ") }
        return text + " (workbench help \(first))"
    }

    static func unknown(_ word: String) -> String {
        "unknown command '\(word)'. Commands: \(commandNames().joined(separator: ", "))"
    }
}
