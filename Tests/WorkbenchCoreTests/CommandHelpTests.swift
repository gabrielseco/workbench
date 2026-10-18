import Foundation
import Testing

@testable import WorkbenchCore

private struct Ran {
    var code: Int32?
    var stdout: String
    var stderr: String
}

/// Runs the built binary in `directory`, which needs not be a project.
private func workbench(_ arguments: [String], in directory: URL) async throws -> Ran {
    var spawn = SpawnRequest(
        executable: WorkbenchBinary.executable, arguments: arguments,
        environment: ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "USER": NSUserName()],
        workingDirectory: directory, timeout: 60)
    spawn.snapshotInterval = 3600
    let run = try ProcessRunner.start(spawn)
    var lines: [String] = []
    var exit: ProcessExit?
    for await event in run.events {
        if case .line(let line) = event { lines.append(line) }
        if case .exited(let e) = event { exit = e }
    }
    var code: Int32?
    if case .exited(let c)? = exit?.termination { code = c }
    return Ran(code: code, stdout: lines.joined(separator: "\n"), stderr: exit?.stderrTail ?? "")
}

private func emptyDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("wb-help-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// The command names as `workbench help` lists them: its two-space entries, not their continuation lines.
private func commandNames(from usage: String) -> [String] {
    var seen: [String] = []
    for line in usage.components(separatedBy: "\n") where line.hasPrefix("  ") && !line.hasPrefix("   ") {
        let name = line.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
        if name.first?.isLetter == true, !seen.contains(name) { seen.append(name) }
    }
    return seen
}

@Suite struct CommandHelpTests {
    @Test func everyCommandInTheUsageBlockAnswersHelpThreeWaysAndTheTextHasWhatAnAgentNeeds() async throws {
        let dir = try emptyDirectory()
        let names = commandNames(from: try await workbench(["help"], in: dir).stdout)
        #expect(names.count >= 20, "\(names)")
        for name in names {
            let long = try await workbench([name, "--help"], in: dir)
            let short = try await workbench([name, "-h"], in: dir)
            let word = try await workbench(["help", name], in: dir)
            #expect(long.code == 0 && short.code == 0 && word.code == 0, "\(name)")
            #expect(long.stdout == short.stdout && long.stdout == word.stdout, "\(name): the three forms differ")
            #expect(long.stdout.hasPrefix("workbench \(name)\n"), "\(name)")
            // `changes:` and `example:` are one table: a command added to the usage block without them fails here.
            for part in ["\nchanges: ", "\nexample: workbench ", "\n--json: ", "\nexit: "] {
                #expect(long.stdout.contains(part), "\(name) has no \(part.dropFirst())")
            }
        }
    }

    @Test func aMultiFormCommandShowsEveryFormAndAQueryShowsOne() async throws {
        let dir = try emptyDirectory()
        let plan = try await workbench(["help", "plan"], in: dir).stdout
        #expect(plan.contains("plan show [id]") && plan.contains("plan edit [id]") && plan.contains("--again"))
        let grant = try await workbench(["grant", "--help"], in: dir).stdout
        #expect(grant.contains("grant [id] <n> --once|--thread|--never") && grant.contains("--json: yes"))
        let goal = try await workbench(["help", "goal"], in: dir).stdout
        #expect(goal.contains("goal new <name>") && goal.contains("goal approve [id]"))

        #expect(try await workbench(["help", "plan", "show"], in: dir).stdout.contains("plan show [id]"))
        let show = try await workbench(["plan", "show", "--help"], in: dir).stdout
        #expect(show.contains("plan show [id]") && !show.contains("plan edit [id]") && !show.contains("--again"))
        let ship = try await workbench(["ship", "-h"], in: dir).stdout
        #expect(ship.contains("[--watch|-w") && ship.contains("exit 10 not accepted"))
    }

    @Test func helpNeedsNoProjectAndChangesNothing() async throws {
        let dir = try emptyDirectory()
        for arguments in [["ship", "--help"], ["help", "doctor"], ["new", "--help"], ["help"]] {
            let ran = try await workbench(arguments, in: dir)
            #expect(ran.code == 0 && ran.stderr.isEmpty, "\(arguments): \(ran.stderr)")
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty, "nothing was created")

        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        let log = try Data(contentsOf: fx.project.eventsURL(id))
        for arguments in [["status", "--help"], ["run", "-h"], ["help", "accept"]] {
            #expect(try await workbench(arguments, in: fx.repo).code == 0)
        }
        #expect(try Data(contentsOf: fx.project.eventsURL(id)) == log, "no event was written")
        #expect(!FileManager.default.fileExists(atPath: fx.project.worktreesDirectory.appendingPathComponent(id).path))
    }

    @Test func aUsageErrorKeepsOneLineAndGainsTheSynopsis() async throws {
        let dir = try emptyDirectory()
        let bad = try await workbench(["ship", "--bogus"], in: dir)
        #expect(bad.code == 2 && bad.stdout.isEmpty)
        let lines = bad.stderr.split(separator: "\n").filter { !$0.isEmpty }
        #expect(lines.count == 1, "\(bad.stderr)")
        #expect(bad.stderr.contains("unexpected argument '--bogus'"))
        #expect(bad.stderr.contains("usage: ship [id] [--yes]") && bad.stderr.contains("[--review-loop]"))
        #expect(bad.stderr.contains("(workbench help ship)"))

        let many = try await workbench(["plan", "--bogus"], in: dir)
        #expect(many.stderr.contains("plan show [id]") && many.stderr.contains("plan edit [id]"))

        let json = try await workbench(["status", "--bogus", "--json"], in: dir)
        #expect(json.code == 2 && json.stderr.isEmpty)
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(json.stdout.utf8)) as? [String: Any])
        let message = try #require((object["error"] as? [String: Any])?["message"] as? String)
        #expect(message.contains("usage: status [id] [--all]") && message.contains("(workbench help status)"))
    }

    @Test func everyKindOfUsageFailureOfAKnownCommandCarriesTheSynopsis() async throws {
        let fx = try await RunnerFixture()
        struct Case {
            var arguments: [String]
            var says: String
            var synopsis: String
        }
        let cases = [
            Case(
                arguments: ["doctor", "stray"], says: "unexpected argument 'stray'",
                synopsis: "usage: doctor [--base <branch>]"),
            Case(arguments: ["run", "--feedback"], says: "--feedback needs a value", synopsis: "usage: run [--feedback"),
            // An error of another type that maps to `usage`: a thread name git would refuse.
            Case(arguments: ["goal", "new", "Bad Name!"], says: "is not a usable name", synopsis: "usage: goal new <name>"),
            Case(arguments: ["ship", "--json"], says: "--json is available on", synopsis: "usage: ship [id]"),
        ]
        for item in cases {
            let ran = try await workbench(item.arguments, in: fx.repo)
            let text = ran.stderr + ran.stdout
            #expect(ran.code == 2, "\(item.arguments): exit \(String(describing: ran.code)): \(text)")
            #expect(text.contains(item.says) && text.contains(item.synopsis), "\(item.arguments): \(text)")
            #expect(text.contains("(workbench help \(item.arguments[0]))"), "\(item.arguments): \(text)")
        }
    }

    @Test func anUnknownCommandIsAUsageErrorThatListsTheCommands() async throws {
        let dir = try emptyDirectory()
        let ran = try await workbench(["help", "frobnicate"], in: dir)
        #expect(ran.code == 2 && ran.stdout.isEmpty)
        #expect(ran.stderr.contains("unknown command 'frobnicate'") && ran.stderr.contains("Commands: new, init"))
        #expect(ran.stderr.contains("ship") && ran.stderr.contains("abandon"))
        let plain = try await workbench(["help"], in: dir)
        #expect(plain.code == 0 && plain.stdout.hasPrefix("usage: workbench <command>"))
        #expect(try await workbench(["frobnicate", "--help"], in: dir).code == 2)
    }

    @Test func anOptionsValueThatReadsHelpIsAValue() async throws {
        let dir = try emptyDirectory()
        // `--feedback` takes text; `run` then fails for want of a thread, as it would with any other text.
        let value = try await workbench(["run", "--feedback", "--help"], in: dir)
        #expect(value.code != 0 && !value.stdout.hasPrefix("workbench run"), "\(value.stdout)")
        // Every option that takes a value, not only the ones main.swift lists: `--from`, `--spec`, `--pr`.
        for arguments in [["goal", "new", "demo", "--from", "--help"], ["pr-review", "--pr", "--help"]] {
            let ran = try await workbench(arguments, in: dir)
            #expect(ran.code != 0 && !ran.stdout.hasPrefix("workbench "), "\(arguments): \(ran.stdout)")
        }
        // The value is whatever follows the option, even a word that looks like another option: this asks for help.
        let after = try await workbench(["run", "--feedback", "--model", "--help"], in: dir)
        #expect(after.code == 0 && after.stdout.hasPrefix("workbench run"), "\(after.stdout) \(after.stderr)")
        // `log -f` is a flag, not an option that takes a value.
        let follow = try await workbench(["log", "-f", "--help"], in: dir)
        #expect(follow.code == 0 && follow.stdout.hasPrefix("workbench log"))
    }
}
