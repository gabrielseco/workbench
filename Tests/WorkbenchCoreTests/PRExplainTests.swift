import Foundation
import Testing

@testable import WorkbenchCore

/// A `gh` named `gh` in a folder of its own, so the CLI finds it on PATH; it answers `pr view` with canned JSON or fails.
private struct ExplainGH {
    let dir: URL
    var runner: GitRunner {
        GitRunner(executable: dir.appendingPathComponent("gh"), environment: ["PATH": "/usr/bin:/bin"], timeout: 10)
    }
    var seenArgs: String { (try? String(contentsOf: dir.appendingPathComponent("args"), encoding: .utf8)) ?? "" }

    init(in r: ReviewedPR, fails: Bool = false) throws {
        dir = r.fx.repo.deletingLastPathComponent().appendingPathComponent("gh-explain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = """
            {"headRefName":"workbench/\(r.id)","baseRefName":"main","title":"fix: the thing","body":"It fixes the thing.",\
            "state":"OPEN","isCrossRepository":false}
            """
        let script = dir.appendingPathComponent("gh")
        try """
            #!/bin/sh
            echo "$@" >> "\(dir.path)/args"
            \(fails ? "echo 'HTTP 404: not found' >&2; exit 1" : "cat <<'EOF'\n\(json)\nEOF")
            """.write(to: script, atomically: true, encoding: .utf8)
        chmod(script.path, 0o755)
    }
}

private struct Ran {
    var code: Int32?
    var stdout: [String]
    var stderr: String
}

/// The built `workbench` in the fixture's repository, with the fake `codex` as `[providers.codex] executable`.
/// With no `gh`, HOME is an empty folder too: `gh` is also looked for in the usual install places under it.
private func workbench(_ arguments: [String], _ r: ReviewedPR, gh: ExplainGH?) async throws -> Ran {
    let path = (gh.map { "\($0.dir.path):" } ?? "") + "/usr/bin:/bin"
    var home = NSHomeDirectory()
    if gh == nil {
        let empty = r.fx.repo.deletingLastPathComponent().appendingPathComponent("home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        home = empty.path
    }
    var spawn = SpawnRequest(
        executable: WorkbenchBinary.executable, arguments: arguments,
        environment: [
            "PATH": path, "HOME": home, "USER": NSUserName(), "CODEX_FAKE_DIR": r.codex.dir.path,
        ],
        workingDirectory: r.fx.repo, timeout: 120)
    spawn.snapshotInterval = 3600
    var lines: [String] = []
    var exit: ProcessExit?
    for await event in try ProcessRunner.start(spawn).events {
        if case .line(let line) = event { lines.append(line) }
        if case .exited(let e) = event { exit = e }
    }
    var code: Int32?
    if case .exited(let c)? = exit?.termination { code = c }
    return Ran(code: code, stdout: lines, stderr: exit?.stderrTail ?? "")
}

/// A pull request #12 on origin with its base there too, and the fake `codex` set as the project's Codex.
private func explainedPR(answer: String? = "# The thing\n\nIt fixes the thing.\n") async throws -> ReviewedPR {
    let r = try await reviewedPR(answer: answer)
    _ = try await r.fx.git.run(["push", "-q", "origin", "main:refs/heads/main"], in: r.fx.repo)
    let url = r.fx.project.configURL
    let config = try String(contentsOf: url, encoding: .utf8) + "\n[providers.codex]\nexecutable = \"\(r.codex.path)\"\n"
    try config.write(to: url, atomically: true, encoding: .utf8)
    var updated = r
    updated.config = try Config.load(from: url)
    return updated
}

@Suite(.processGate) struct PRExplainTests {
    private func explain(
        _ r: ReviewedPR, gh: ExplainGH? = nil, spec: (text: String, path: String)? = nil, again: Bool = false,
        out: URL? = nil
    ) async throws -> PRExplainResult {
        try await r.fx.service.explainPullRequest(
            number: 12, spec: spec, config: r.config, gh: (gh ?? ExplainGH(in: r)).runner, again: again, out: out,
            codexPath: r.codex.path, environment: r.codex.environment(), timeout: 30, capacityBackoff: { _ in 0 })
    }

    private func kept(_ r: ReviewedPR, head: String? = nil) -> URL {
        r.fx.project.workbenchDirectory.appendingPathComponent("explains/pr-12-\((head ?? r.head).prefix(7)).md")
    }

    private func repoState(_ r: ReviewedPR) async throws -> String {
        let here = try await r.fx.git.run(["for-each-ref", "--format=%(refname) %(objectname)", "refs/heads"], in: r.fx.repo)
        let origin = try await r.fx.git.run(["for-each-ref", "--format=%(refname) %(objectname)"], in: r.bare)
        let head = try await r.fx.git.run(["rev-parse", "HEAD"], in: r.fx.repo)
        let status = try await r.fx.git.run(
            ["status", "--porcelain", "--untracked-files=all", "--", ":!.workbench"], in: r.fx.repo)
        let trees = try await r.fx.git.run(["worktree", "list", "--porcelain"], in: r.fx.repo)
        return [here.stdout, origin.stdout, head.stdout, status.stdout, trees.stdout].joined(separator: "\n--\n")
    }

    @Test func anExplanationRunsReadOnlyCodexInAThrowawayCheckoutAndChangesNothing() async throws {
        let r = try await explainedPR()
        let gh = try ExplainGH(in: r)
        let before = try await repoState(r)
        let events = try r.fx.events(r.id).count
        let result = try await explain(r, gh: gh)

        #expect(result.failure == nil && result.file != nil, "\(result.failure ?? "")")
        let call = try #require(r.codex.calls.first)
        #expect(call.hasPrefix("exec -s read-only -C "), "\(call)")
        let cwd = try #require(r.codex.read("cwds")).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(cwd.hasSuffix("/explains/pr-12-\(r.head.prefix(7))/round-1.tree"), "it ran in the throwaway checkout: \(cwd)")
        #expect(r.codex.read("tree_1")?.contains("a.txt") == true, "the checkout is the pull request's head")
        #expect(try await repoState(r) == before, "branches, origin, HEAD, the working tree and the worktrees are as they were")
        #expect(try r.fx.events(r.id).count == events, "nothing is written to a thread's log")
        let ghCalls = gh.seenArgs.split(separator: "\n")
        #expect(ghCalls.count == 1 && ghCalls.allSatisfy { $0.hasPrefix("pr view 12 --json ") }, "gh only read: \(gh.seenArgs)")
        let brief = try #require(r.codex.read("brief_1"))
        #expect(brief.contains("diff.patch") && !brief.contains("VERDICT:"), "an explanation brief, with no verdict asked")
    }

    @Test func theFileIsTheBodyOnlyAndTheLastStdoutLineIsItsAbsolutePath() async throws {
        let r = try await explainedPR(answer: "---\ntitle: x\n---\n\n# The thing\n\nIt fixes the thing.\n\n")
        let ran = try await workbench(["explain-pr", "--pr", "12"], r, gh: ExplainGH(in: r))

        #expect(ran.code == 0, "\(ran.stdout) \(ran.stderr)")
        let last = try #require(ran.stdout.last)
        #expect(last == kept(r).path && last.hasPrefix("/"), "\(ran.stdout)")
        let text = try String(contentsOf: kept(r), encoding: .utf8)
        #expect(text == "# The thing\n\nIt fixes the thing.\n", "the body alone, front matter dropped: \(text)")
    }

    @Test func outWritesThereAndWithoutItTheFileIsKeptUnderExplains() async throws {
        let r = try await explainedPR()
        let kept = try await explain(r)
        #expect(kept.file == self.kept(r), "\(String(describing: kept.file))")
        #expect(FileManager.default.fileExists(atPath: self.kept(r).path))

        let out = r.fx.repo.deletingLastPathComponent().appendingPathComponent("note-\(UUID().uuidString).md")
        let ran = try await workbench(["explain-pr", "--pr", "12", "--out", out.path, "--again"], r, gh: ExplainGH(in: r))
        #expect(ran.code == 0 && ran.stdout.last == out.path, "\(ran.stdout) \(ran.stderr)")
        #expect(try String(contentsOf: out, encoding: .utf8) == "# The thing\n\nIt fixes the thing.\n")

        let missing = r.fx.repo.appendingPathComponent("no/such/folder/x.md")
        let refused = try await workbench(["explain-pr", "--pr", "12", "--out", missing.path], r, gh: ExplainGH(in: r))
        #expect(refused.code == 6 && refused.stderr.contains("does not exist"), "\(refused.stderr)")
        #expect(r.codex.runs == 2, "a refused --out spawns nothing")
    }

    @Test func anUnmovedHeadReusesTheFileUnlessAgainAndAMovedHeadIsExplainedAfresh() async throws {
        let r = try await explainedPR()
        let first = try await explain(r)
        #expect(!first.reused && r.codex.runs == 1)

        let second = try await explain(r)
        #expect(second.reused && second.file == kept(r) && r.codex.runs == 1, "the same head reuses the kept file")
        let out = r.fx.repo.deletingLastPathComponent().appendingPathComponent("reused-\(UUID().uuidString).md")
        let copied = try await explain(r, out: out)
        #expect(copied.reused && copied.file == out && r.codex.runs == 1, "a reused file is written to --out too")
        #expect(try String(contentsOf: out, encoding: .utf8) == String(contentsOf: kept(r), encoding: .utf8))

        try r.codex.put("answer_2", "# Again\n\nAsked once more.\n")
        let again = try await explain(r, again: true)
        #expect(!again.reused && r.codex.runs == 2, "--again asks once more")
        #expect(try String(contentsOf: kept(r), encoding: .utf8) == "# Again\n\nAsked once more.\n")

        // The pull request's branch moves on origin: a new head, a new file, a new run.
        let tree = try await shipOut(["rev-parse", "\(r.head)^{tree}"], r.fx.repo, r.fx)
        let moved = try await shipOut(["commit-tree", tree, "-p", r.head, "-m", "moved"], r.fx.repo, r.fx)
        _ = try await r.fx.git.run(["push", "-q", "origin", "\(moved):refs/heads/workbench/\(r.id)"], in: r.fx.repo)
        let fresh = try await explain(r)
        #expect(!fresh.reused && fresh.headSHA == moved && r.codex.runs == 3, "\(fresh.failure ?? "")")
        #expect(fresh.file == kept(r, head: moved) && FileManager.default.fileExists(atPath: kept(r, head: moved).path))
    }

    @Test(arguments: [("empty", "  \n\n"), ("front matter only", "---\ntitle: x\n---\n"), ("missing", nil)])
    func anEmptyOrMissingAnswerIsAFailureAndWritesNoFile(label: String, answer: String?) async throws {
        let r = try await explainedPR(answer: answer)
        let result = try await explain(r)
        #expect(result.file == nil && result.failure != nil, "\(label)")
        #expect(!FileManager.default.fileExists(atPath: kept(r).path), "\(label): no file is reported or left")
        let ran = try await workbench(["explain-pr", "--pr", "12"], r, gh: ExplainGH(in: r))
        #expect(ran.code == 1 && ran.stderr.contains("no explanation of pull request #12"), "\(label): \(ran.stderr)")
        #expect(ran.stdout.allSatisfy { !$0.hasPrefix("/") }, "\(label): no path on stdout: \(ran.stdout)")
        #expect(r.codex.read("brief_1") != nil, "\(label): the agent did run")
    }

    @Test func aSpecFileReplacesThePullRequestText() async throws {
        let r = try await explainedPR()
        let spec = r.fx.repo.deletingLastPathComponent().appendingPathComponent("spec.md")
        try "THE SPEC: never block the main actor\n".write(to: spec, atomically: true, encoding: .utf8)
        let ran = try await workbench(["explain-pr", "--pr", "12", "--spec", spec.path], r, gh: ExplainGH(in: r))
        #expect(ran.code == 0, "\(ran.stderr)")
        let brief = try #require(r.codex.read("brief_1"))
        #expect(brief.contains("THE SPEC: never block the main actor") && !brief.contains("It fixes the thing."))

        let unreadable = try await workbench(
            ["explain-pr", "--pr", "12", "--spec", spec.path + ".missing"], r, gh: ExplainGH(in: r))
        let asReview = try await workbench(
            ["pr-review", "--pr", "12", "--spec", spec.path + ".missing"], r, gh: ExplainGH(in: r))
        #expect(unreadable.code == 6 && unreadable.code == asReview.code, "\(unreadable.stderr)")
    }

    @Test func badInputFailsAsPRReviewByNumberDoes() async throws {
        let r = try await explainedPR()
        struct Case {
            var label: String
            var args: [String]
            var gh: ExplainGH?
            var code: Int32
            var said: String
        }
        let cases = [
            Case(label: "no --pr", args: [], gh: try ExplainGH(in: r), code: 2, said: "--pr"),
            Case(label: "not a number", args: ["--pr", "twelve"], gh: try ExplainGH(in: r), code: 2, said: "'twelve'"),
            Case(label: "zero", args: ["--pr", "0"], gh: try ExplainGH(in: r), code: 2, said: "'0'"),
            Case(label: "no gh", args: ["--pr", "12"], gh: nil, code: 6, said: "`gh` is not on PATH"),
            Case(label: "unreadable", args: ["--pr", "12"], gh: try ExplainGH(in: r, fails: true), code: 1, said: "HTTP 404"),
        ]
        // `gh` is also looked for in /opt/homebrew/bin and /usr/local/bin, so where one is installed there the "no gh" case
        // reaches it; it must still fail as `pr-review --pr` does, which is checked below in every case.
        let installed = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"].contains {
            FileManager.default.isExecutableFile(atPath: $0)
        }
        for c in cases {
            let explained = try await workbench(["explain-pr"] + c.args, r, gh: c.gh)
            if !(c.label == "no gh" && installed) {
                #expect(explained.code == c.code && explained.stderr.contains(c.said), "\(c.label): \(explained.stderr)")
            }
            // `pr-review` without `--pr` is the thread's review, a different command line; the rest match it.
            if !c.args.isEmpty {
                let reviewed = try await workbench(["pr-review"] + c.args, r, gh: c.gh)
                #expect(reviewed.code == explained.code, "\(c.label): pr-review --pr exits \(String(describing: reviewed.code))")
            }
        }
        #expect(r.codex.runs == 0, "nothing was spawned")
    }
}
