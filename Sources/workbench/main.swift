import Foundation
import WorkbenchCore

let usage = """
    usage: workbench <command>

    setup
      new <name|path> [--in <dir>] [--seed <path>]... [--nested]
                                 create a project: git repo on main with one empty commit, --seed copies into
                                 vendor/, .workbench/config.toml. Location: a path, else --in, else projects_dir
                                 in ~/.workbench/config.toml (also claude_path, model); refuses a
                                 non-empty target and a place inside another repo unless --nested
      init                       write .workbench/config.toml
      config                     show the resolved config and the command a turn would run
      doctor [--base <branch>]   run the declared setup and check in a throwaway worktree; changes nothing

    one thread at a time
      goal new <name>            start a thread with a draft goal to fill in   [--base <branch>]
                                 --from <goal-file> copies its request, criteria and out of scope into the draft
                                 --update <branch> continues that branch of origin (ship pushes to it and records its PR)
      goal approve [id]          approve the goal; any later edit returns it to draft
                                 refused while a proof names a command a run cannot execute
                                 (--allow-unrunnable-proofs to approve anyway; also on run, send-back;
                                 a proof written "- proof (by hand): ..." is skipped)
      run                        run Claude on the approved goal in a worktree [--feedback "<text>"]
                                 (local edits in your checkout are left out; --allow-dirty is ignored)
      send-back "<note>" [--budget <usd>]  next turn with your note and the failed check's output
      stop                       ask the running turn to stop cleanly
      log [-f] [-v] [--seq <n>]  what happened; -f follows, -v shows every stream line, --seq one event in full
      status [id] [--all]        where the thread stands; --all: one line per thread
      review [id] [--patch <path>]  the goal's criteria, the diff, the check and denied tools; changes nothing
      judge [id] [--again] [--model <name>] [--budget <usd>]
                                 ask a second, read-only Claude run whether the check, the verify step, its
                                 screenshots and the diff show each criterion holds; advisory, shown by review
                                 beside your own checks, never changes accept or ship; once per turn unless --again
      pr-review --pr <n> [--spec <file>] [--again]
                                 the same review for a pull request no thread made (one written by hand): its own
                                 text is the goal, or the file; kept under .workbench/reviews/, no rounds counted
      pr-review [id] [--again]   after ship: Codex reviews the pull request, read-only, in a throwaway checkout
                                 of its head; prints the findings and records the round (shown by review);
                                 at most max_rounds ([pr_review]) per pull request, --again does not lift that
                                 exit 0 clean, 15 findings to fix, 1 no verdict this time, 6 refused
      review-stage <name> [id] [--again]
                                 the same for the stage <name> of review.stages (pr-review is `pr-review`), with its
                                 own rounds; a stage whose applies_to matches no changed path is skipped (exit 0)
      accept [id] [-m <msg>] [--yes]  commit the work on its branch and end the thread; no push
      ship [id] [--yes] [--no-describe] [--refresh-description] [--no-screenshots|--screenshots] [--keep-worktree]
           [--watch|-w [--timeout <min>] [--interval <s>]] [--review-loop]
                                 push the accepted branch and open its pull request; asks first, after
                                 showing the title and body (written by a read-only Claude turn from the
                                 goal, diff and check; --no-describe uses the goal's text);
                                 for a thread from goal new --update it proposes edits to the PR's own
                                 title and sections and applies them only on a second yes, or with
                                 --refresh-description; --no-describe skips the proposal;
                                 screenshots the verify step left are put in the PR with `pr-shots`, if it
                                 is installed (--no-screenshots skips it; --screenshots tries again for a shipped thread);
                                 --watch then follows the CI checks (read-only);
                                 --review-loop then has Codex review the pull request and, for each finding round,
                                 starts a follow-up thread on the same branch, runs it and its check, asks before
                                 pushing it (--yes skips that) and reviews again, up to max_rounds; never merges
                                 exit 10 not accepted, 11 already shipped (URL printed), 12 push rejected,
                                 13 a check failed, 14 no result in time
      clean [--yes] [--closed]   remove the worktree and local branch of shipped threads whose pull request is
                                 merged (or closed, with --closed); a dry run unless --yes
      discard [id] [--yes]       throw the work away: delete the worktree and branch, keep the log
      abandon [--force]          end the thread without accepting its work; uncommitted changes in its worktree
                             are saved as abandon.patch in the thread folder first, the branch is kept

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
    "--feedback", "-f", "-m", "--message", "--budget", "--model", "--base", "--update", "--patch", "--seq", "--timeout",
    "--interval", "--in", "--seed",
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
    case "judge":
        exit(try await Commands.judge(Array(arguments.dropFirst())))
    case "pr-review":
        exit(try await Commands.prReview(Array(arguments.dropFirst())))
    case "review-stage":
        exit(try await Commands.reviewStage(Array(arguments.dropFirst())))
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
