import Foundation
#if canImport(Glibc)
// glibc's `stdout` is a mutable global, which Swift 6 rejects unless the import is `@preconcurrency`.
@preconcurrency import Glibc
#endif
import WorkbenchCore

func report(_ error: Error, arguments: [String]) -> Never {
    let kind = failureKind(of: error)
    switch error {
    case _ where kind == .usage:
        // Whatever the error type, a usage failure of a known command says what the command takes.
        exit(fail(kind, Help.withSynopsis("\(error)", arguments: arguments)))
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
    "--interval", "--in", "--seed", "--turn",
]
// Help comes before anything else: it needs no project and changes nothing.
if let query = Help.request(arguments, valueOptions: Help.valueOptions(adding: valueOptions)) {
    guard let text = Help.text(for: query) else { exit(fail(.usage, Help.unknown(query[0]))) }
    out(text)
    exit(0)
}

if let at = arguments.indices.first(where: {
    arguments[$0] == "--json" && !($0 > 0 && valueOptions.contains(arguments[$0 - 1]))
}) {
    arguments.remove(at: at)
    Output.json = true
    if !["status", "review", "log", "grant", "doctor"].contains(arguments.first ?? "") {
        let available = "--json is available on status, review, log, grant and doctor"
        exit(fail(.usage, Help.withSynopsis(available, arguments: arguments)))
    }
}

do {
    switch arguments.first {
    case "version", "--version":
        out("workbench \(Workbench.version)")
    case nil, "help", "--help", "-h":
        out(workbenchUsage)
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
        case "draft": exit(try await Commands.goalDraft(Array(arguments.dropFirst(2))))
        case "approve": try await Commands.goalApprove(Array(arguments.dropFirst(2)))
        default:
            throw CLIError.usage("usage: workbench goal new <name> | goal draft <name> | goal approve [id]")
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
    case "grant":
        try await Commands.grant(Array(arguments.dropFirst()))
    case "open":
        try await Commands.open(Array(arguments.dropFirst()))
    case "compact":
        exit(try await Commands.compact(Array(arguments.dropFirst())))
    case "judge":
        exit(try await Commands.judge(Array(arguments.dropFirst())))
    case "verifier":
        exit(try await Commands.verifier(Array(arguments.dropFirst())))
    case "plan":
        exit(try await Commands.plan(Array(arguments.dropFirst())))
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
    report(error, arguments: arguments)
}
