import Foundation
import WorkbenchCore

let usage = """
    usage: workbench <command>

    setup
      new <name|path> [--in <dir>] [--seed <path>]... [--nested]
                                 create a project: git repo on main with one empty commit, --seed copies into
                                 vendor/, .workbench/config.toml. Location: a path, else --in, else projects_dir
                                 in ~/.config/workbench/config.toml (also claude_path, model); refuses a
                                 non-empty target and a place inside another repo unless --nested
      init                       write .workbench/config.toml
      config                     show the resolved config and the command a turn would run
      doctor [--base <branch>]   run the declared setup and check in a throwaway worktree; changes nothing

    one thread at a time
      goal new <name>            start a thread with a draft goal to fill in   [--base <branch>]
      goal approve [id]          approve the goal; any later edit returns it to draft
                                 refused while a proof names a command a run cannot execute
                                 (--allow-unrunnable-proofs to approve anyway; also on run, send-back)
      run                        run Claude on the approved goal in a worktree [--feedback "<text>"]
                                 (local edits in your checkout are left out; --allow-dirty is ignored)
      send-back "<note>" [--budget <usd>]  next turn with your note and the failed check's output
      stop                       ask the running turn to stop cleanly
      log [-f] [-v] [--seq <n>]  what happened; -f follows, -v shows every stream line, --seq one event in full
      status [id] [--all]        where the thread stands; --all: one line per thread
      review [id] [--patch <path>]  the goal's criteria, the diff, the check and denied tools; changes nothing
      accept [id] [-m <msg>] [--yes]  commit the work on its branch and end the thread; no push
      ship [id] [--yes] [--keep-worktree] [--watch [--timeout <min>] [--interval <s>]]
                                 push the accepted branch and open its pull request; asks first;
                                 --watch then follows the CI checks (read-only)
                                 exit 10 not accepted, 11 already shipped (URL printed), 12 push rejected,
                                 13 a check failed, 14 no result in time
      clean [--yes] [--closed]   remove the worktree and local branch of shipped threads whose pull request is
                                 merged (or closed, with --closed); a dry run unless --yes
      discard [id] [--yes]       throw the work away: delete the worktree and branch, keep the log
      abandon [--force]          end the thread without accepting its work

      --json on status, review and log; exit codes: docs/spec/exit-codes.md

      version
    """

func report(_ error: Error) -> Never {
    let kind = failureKind(of: error)
    switch error {
    case is ConfigError, is GoalParseError:
        // The core's text starts with the first problem; the kind says what it is about.
        exit(fail(kind, "\(error)"))
    default:
        exit(fail(kind, "\(error)"))
    }
}

// Progress must show up as it happens even when output is piped or redirected (`workbench run | tee`).
setvbuf(stdout, nil, _IOLBF, 0)

var arguments = Array(CommandLine.arguments.dropFirst())
// `--json` is global: it is taken out here so every command sees the same arguments, and only the read
// commands may use it.
// An option's value that happens to read `--json` is a value, not the flag.
let valueOptions: Set = [
    "--feedback", "-f", "-m", "--message", "--budget", "--base", "--patch", "--seq", "--timeout", "--interval", "--in", "--seed",
]
if let at = arguments.indices.first(where: {
    arguments[$0] == "--json" && !($0 > 0 && valueOptions.contains(arguments[$0 - 1]))
}) {
    arguments.remove(at: at)
    Output.json = true
    if !["status", "review", "log"].contains(arguments.first ?? "") {
        exit(fail(.usage, "--json is available on status, review and log"))
    }
}

do {
    switch arguments.first {
    case "version", "--version":
        out("workbench \(Workbench.version)")
    case nil, "help", "--help", "-h":
        out(usage)
    case "new":
        try await Commands.newProject(Array(arguments.dropFirst()))
    case "init":
        try await Commands.initProject()
    case "config":
        try await Commands.config()
    case "doctor":
        exit(try await Commands.doctor(Array(arguments.dropFirst())))
    case "goal":
        switch arguments.dropFirst().first {
        case "new": try await Commands.goalNew(Array(arguments.dropFirst(2)))
        case "approve": try await Commands.goalApprove(Array(arguments.dropFirst(2)))
        default: throw CLIError.usage("usage: workbench goal new <name> | workbench goal approve [id]")
        }
    case "run":
        exit(try await Commands.run(Array(arguments.dropFirst())))
    case "send-back":
        exit(try await Commands.sendBack(Array(arguments.dropFirst())))
    case "stop":
        try await Commands.stop(Array(arguments.dropFirst()))
    case "log":
        try await Commands.log(Array(arguments.dropFirst()))
    case "status":
        try await Commands.status(Array(arguments.dropFirst()))
    case "review":
        try await Commands.review(Array(arguments.dropFirst()))
    case "accept":
        try await Commands.accept(Array(arguments.dropFirst()))
    case "ship":
        exit(try await Commands.ship(Array(arguments.dropFirst())))
    case "clean":
        exit(try await Commands.clean(Array(arguments.dropFirst())))
    case "discard":
        try await Commands.discard(Array(arguments.dropFirst()))
    case "abandon":
        try await Commands.abandon(Array(arguments.dropFirst()))
    default:
        throw CLIError.usage("unknown command '\(arguments[0])'. `workbench help` lists the commands.")
    }
} catch {
    report(error)
}
