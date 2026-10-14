import Foundation
import WorkbenchCore

let usage = """
    usage: workbench <command>

    setup
      init                       write .workbench/config.toml
      config                     show the resolved config and the command a turn would run

    one thread at a time
      goal new <name>            start a thread with a draft goal to fill in   [--base <branch>]
      goal approve [id]          approve the goal; any later edit returns it to draft
      run                        run Claude on the approved goal in a worktree [--feedback "<text>"]
      send-back "<note>" [--budget <usd>]  next turn with your note and the failed check's output
      stop                       ask the running turn to stop cleanly
      log [-f] [-v] [--seq <n>]  what happened; -f follows, -v shows every stream line, --seq one event in full
      status                     where the thread stands
      review [id] [--patch <path>]  the goal's criteria, the diff, the check and denied tools; changes nothing
      accept [id] [-m <msg>] [--yes]  commit the work on its branch and end the thread; no push
      ship [id] [--yes]          push the accepted branch and open its pull request; asks first
                                 exit 3 not accepted, 4 already shipped (URL printed), 5 push rejected
      discard [id] [--yes]       throw the work away: delete the worktree and branch, keep the log
      abandon [--force]          end the thread without accepting its work

      version
    """

func report(_ error: Error) -> Never {
    switch error {
    case let e as CLIError:
        err("workbench: \(e)")
        if case .usage = e { exit(2) }
        exit(1)
    case let e as ConfigError:
        err("workbench: invalid config\n\(e)")
        exit(2)
    case let e as GoalParseError:
        err("workbench: invalid goal\n\(e)")
        exit(2)
    default:
        err("workbench: \(error)")
        exit(1)
    }
}

// Progress must show up as it happens even when output is piped or redirected (`workbench run | tee`).
setvbuf(stdout, nil, _IOLBF, 0)

let arguments = Array(CommandLine.arguments.dropFirst())

do {
    switch arguments.first {
    case "version", "--version":
        out("workbench \(Workbench.version)")
    case nil, "help", "--help", "-h":
        out(usage)
    case "init":
        try await Commands.initProject()
    case "config":
        try await Commands.config()
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
    case "discard":
        try await Commands.discard(Array(arguments.dropFirst()))
    case "abandon":
        try await Commands.abandon(Array(arguments.dropFirst()))
    default:
        throw CLIError.usage("unknown command '\(arguments[0])'\n\n\(usage)")
    }
} catch {
    report(error)
}
