import Foundation
import Testing

@testable import WorkbenchCore

/// A comment of the fake thread, as GitHub's GraphQL answer has it.
private struct FakeComment {
    var author: String
    var body: String
    var at: String
    var outdated = false

    var json: String {
        let object: [String: Any] = [
            "author": ["login": author], "body": body, "createdAt": at, "diffHunk": "@@ -1,3 +1,3 @@\n line 1\n-old\n+line 2",
            "outdated": outdated,
        ]
        return String(decoding: (try? JSONSerialization.data(withJSONObject: object)) ?? Data(), as: UTF8.self)
    }
}

/// A `gh` named `gh` in a folder of its own. `pr view` answers `pr.json`; `api graphql` answers `thread.json`, or
/// `thread2.json` for the page after the first, or fails with `thread.fail` on stderr. Every call is one line of `args`.
private struct ThreadGH {
    let dir: URL
    var runner: GitRunner {
        GitRunner(executable: dir.appendingPathComponent("gh"), environment: ["PATH": "/usr/bin:/bin"], timeout: 10)
    }
    var calls: [String] {
        ((try? String(contentsOf: dir.appendingPathComponent("args"), encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    init(in r: ReviewedPR, state: String = "OPEN") throws {
        dir = r.fx.repo.deletingLastPathComponent().appendingPathComponent("gh-thread-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try put(
            "pr.json",
            """
            {"headRefName":"workbench/\(r.id)","baseRefName":"main","title":"feat: a calculator","body":"Adds calc.swift.",\
            "state":"\(state)","isCrossRepository":false}
            """)
        try thread()
        let script = dir.appendingPathComponent("gh")
        try """
            #!/bin/sh
            d="\(dir.path)"
            printf '%s|' "$@" | tr '\\n' ' ' >> "$d/args"; echo >> "$d/args"
            case "$1" in
              pr) cat "$d/pr.json" ;;
              api)
                if [ -f "$d/thread.fail" ]; then cat "$d/thread.fail" >&2; exit 1; fi
                case "$*" in *after=*) cat "$d/thread2.json" ;; *) cat "$d/thread.json" ;; esac ;;
              *) echo "unexpected gh $*" >&2; exit 9 ;;
            esac
            """.write(to: script, atomically: true, encoding: .utf8)
        chmod(script.path, 0o755)
    }

    func put(_ name: String, _ text: String) throws {
        try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    /// Writes the thread GitHub answers with.
    func thread(
        pr: Int = 12, line: Int? = 30, originalLine: Int = 30, startLine: Int? = nil, outdated: Bool = false,
        path: String = "src/calc.swift", type: String = "PullRequestReviewThread", repository: String = "o/n",
        comments: [FakeComment] = defaultComments, next: String? = nil, file: String = "thread.json",
        side: String = "RIGHT", startSide: String? = nil
    ) throws {
        let startSide = startSide.map { "\"\($0)\"" } ?? "null"
        let line = line.map(String.init) ?? "null"
        let start = startLine.map(String.init) ?? "null"
        let page = next.map { #"{"hasNextPage":true,"endCursor":"\#($0)"}"# } ?? #"{"hasNextPage":false,"endCursor":null}"#
        try put(
            file,
            """
            {"data":{"node":{"__typename":"\(type)","isOutdated":\(outdated),"isResolved":false,"path":"\(path)",\
            "line":\(line),"originalLine":\(originalLine),"startLine":\(start),"originalStartLine":null,\
            "diffSide":"\(side)","startDiffSide":\(startSide),\
            "pullRequest":{"number":\(pr),"repository":{"nameWithOwner":"\(repository)"}},\
            "comments":{"pageInfo":\(page),"nodes":[\(comments.map(\.json).joined(separator: ","))]}}}}
            """)
    }

    static let defaultComments = [
        FakeComment(author: "ana", body: "FIRST: this divides by zero when b is 0.", at: "2026-11-01T10:00:00Z"),
        FakeComment(author: "bo", body: "SECOND: agreed, guard it.", at: "2026-11-01T11:00:00Z"),
    ]
}

private struct Ran {
    var code: Int32?
    var stdout: [String]
    var stderr: String
}

/// The built `workbench` with the stand-in `gh` first on PATH, run in `folder` (the clone's root by default).
private func workbench(_ arguments: [String], _ r: ReviewedPR, gh: ThreadGH, in folder: URL? = nil) async throws -> Ran {
    var spawn = SpawnRequest(
        executable: WorkbenchBinary.executable, arguments: arguments,
        environment: [
            "PATH": "\(gh.dir.path):/usr/bin:/bin", "HOME": NSHomeDirectory(), "USER": NSUserName(),
            "CODEX_FAKE_DIR": r.codex.dir.path,
        ],
        workingDirectory: folder ?? r.fx.repo, timeout: 120)
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

private let goodAnswer = #"{"reasoning":"b can be 0 at line 30.","proposed_fix":"Guard b == 0 before dividing."}"#
private let threadID = "PRRT_kwDOtest123"

/// Pull request #12 on origin, whose head adds `src/calc.swift` (60 numbered lines), with the fake `codex` as the
/// project's Codex. A folder `src` is in the clone too, to run from. With `base`, `src/calc.swift` is on main first with
/// that text, and the pull request changes it.
private func threadPR(answer: String? = goodAnswer, base: String? = nil) async throws -> ReviewedPR {
    var r = try await reviewedPR(answer: answer)
    let fx = r.fx
    _ = try await fx.git.run(["push", "-q", "origin", "main:refs/heads/main"], in: fx.repo)
    let clone = fx.repo.deletingLastPathComponent().appendingPathComponent("author-\(UUID().uuidString)")
    _ = try await fx.git.run(["clone", "-q", r.bare.path, clone.path], in: fx.repo)
    _ = try await fx.git.run(["checkout", "-q", "workbench/\(r.id)"], in: clone)
    let src = clone.appendingPathComponent("src")
    try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
    if let base {
        try base.write(to: src.appendingPathComponent("calc.swift"), atomically: true, encoding: .utf8)
        _ = try await fx.git.run(["add", "src/calc.swift"], in: clone)
        _ = try await fx.git.run(["-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-qm", "old"], in: clone)
        _ = try await fx.git.run(["push", "-q", "origin", "HEAD:refs/heads/main"], in: clone)
    }
    let text = (1...60).map { "line \($0)" }.joined(separator: "\n") + "\n"
    try text.write(to: src.appendingPathComponent("calc.swift"), atomically: true, encoding: .utf8)
    _ = try await fx.git.run(["add", "src/calc.swift"], in: clone)
    _ = try await fx.git.run(["-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-qm", "calc"], in: clone)
    _ = try await fx.git.run(["push", "-q", "origin", "HEAD"], in: clone)
    r.head = try await shipOut(["rev-parse", "HEAD"], clone, fx)
    try FileManager.default.createDirectory(at: fx.repo.appendingPathComponent("src"), withIntermediateDirectories: true)

    let url = fx.project.configURL
    let config = try String(contentsOf: url, encoding: .utf8) + "\n[providers.codex]\nexecutable = \"\(r.codex.path)\"\n"
    try config.write(to: url, atomically: true, encoding: .utf8)
    r.config = try Config.load(from: url)
    return r
}

@Suite(.processGate) struct ExplainThreadTests {
    private func explain(_ r: ReviewedPR, gh: ThreadGH, thread: String = threadID) async throws -> ThreadExplainResult {
        try await r.fx.service.explainReviewThread(
            number: 12, thread: thread, config: r.config, gh: gh.runner, codexPath: r.codex.path,
            environment: r.codex.environment(), timeout: 30, capacityBackoff: { _ in 0 })
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

    @Test func gathersPRAndThreadContext() async throws {
        let r = try await threadPR()
        let gh = try ThreadGH(in: r)
        // Two pages, the second's comment out of order by time: every comment is read and put oldest first.
        try gh.thread(
            outdated: true,
            comments: [
                FakeComment(author: "ana", body: "FIRST", at: "2026-11-01T10:00:00Z"),
                FakeComment(author: "cy", body: "THIRD", at: "2026-11-01T12:00:00Z", outdated: true),
            ], next: "CURSOR1")
        try gh.thread(
            outdated: true, comments: [FakeComment(author: "bo", body: "SECOND", at: "2026-11-01T11:00:00Z")],
            file: "thread2.json")
        let thread = try await r.fx.service.reviewThread(threadID, pr: 12, gh: gh.runner, originURL: nil)
        #expect(thread.comments.map(\.body) == ["FIRST", "SECOND", "THIRD"])
        #expect(thread.comments.map(\.outdated) == [false, false, true])
        #expect(thread.path == "src/calc.swift" && thread.line == 30 && thread.outdated && !thread.truncated)
        let pages = gh.calls
        #expect(pages.count == 2 && pages[1].contains("after=CURSOR1|"), "\(pages)")
        #expect(pages.allSatisfy { $0.hasPrefix("api|graphql|") && $0.contains("id=\(threadID)|") }, "\(pages)")

        // From a folder inside the clone, with nothing but the number and the id.
        let fresh = try ThreadGH(in: r)
        let ran = try await workbench(
            ["explain-thread", "--pr", "12", "--thread", threadID], r, gh: fresh, in: r.fx.repo.appendingPathComponent("src"))
        #expect(ran.code == 0, "\(ran.stdout) \(ran.stderr)")
        #expect(fresh.calls.first?.hasPrefix("pr|view|12|--json|") == true, "\(fresh.calls)")
        let brief = try #require(r.codex.read("brief_1"))
        #expect(brief.contains("feat: a calculator") && brief.contains("Adds calc.swift."), "title and description")
        #expect(r.codex.read("diff_1")?.contains("+line 30") == true, "the diff of the head against its base")
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data((ran.stdout.last ?? "").utf8)) as? [String: Any])
        #expect(object["head_sha"] as? String == r.head, "the head is origin's tip of the branch")
    }

    @Test func promptHasPRThreadAndCode() async throws {
        let r = try await threadPR()
        let result = try await explain(r, gh: try ThreadGH(in: r))
        #expect(result.failure == nil, "\(result.failure ?? "")")

        let call = try #require(r.codex.calls.first)
        #expect(call.hasPrefix("exec -s read-only -C "), "read-only: \(call)")
        let cwd = try #require(r.codex.read("cwds")).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(cwd.hasSuffix("/explains/pr-12-thread-\(threadID)/round-1.tree"), "in the throwaway checkout: \(cwd)")
        #expect(r.codex.read("tree_1")?.contains("src") == true, "the checkout is the head")

        let brief = try #require(r.codex.read("brief_1"))
        func at(_ text: String) -> String.Index? { brief.range(of: text)?.lowerBound }
        let title = try #require(at("feat: a calculator"))
        let first = try #require(at("FIRST: this divides by zero"))
        let second = try #require(at("SECOND: agreed"))
        let code = try #require(at("> 30 | line 30"))
        #expect(title < first && first < second && second < code, "the pull request, then the thread in order, then the code")
        #expect(brief.contains("src/calc.swift") && brief.contains("diff.patch"), "the path and the diff's file")
        // Twenty lines either side of the commented one, no more, the others unmarked.
        #expect(brief.contains("  10 | line 10") && brief.contains("  50 | line 50"))
        #expect(!brief.contains("| line 9\n") && !brief.contains("| line 51\n") && !brief.contains("> 29 |"))
        // The comments are quoted inside a fence, so they cannot close it.
        let thread = try #require(brief.range(of: "## The thread"))
        let fence = try #require(brief.range(of: "```", range: thread.upperBound..<brief.endIndex))
        #expect(fence.lowerBound < first, "the comments sit inside a fence")

        // A range comment marks every line of the range.
        let ranged = try await threadPR()
        let gh = try ThreadGH(in: ranged)
        try gh.thread(line: 32, startLine: 30)
        _ = try await explain(ranged, gh: gh)
        let rangedBrief = try #require(ranged.codex.read("brief_1"))
        #expect(rangedBrief.contains("> 30 |") && rangedBrief.contains("> 31 |") && rangedBrief.contains("> 32 |"))
        #expect(!rangedBrief.contains("> 33 |"))
    }

    @Test func deletedLineShowsTheBase() async throws {
        // The base has 40 `old` lines; the pull request replaces them with 60 `line` lines. A comment on the left
        // side's line 30 is on `old 30`, not on the head's line 30.
        let base = (1...40).map { "old \($0)" }.joined(separator: "\n") + "\n"
        let r = try await threadPR(base: base)
        let gh = try ThreadGH(in: r)
        try gh.thread(line: 30, startLine: 28, side: "LEFT", startSide: "LEFT")
        let result = try await explain(r, gh: gh)
        #expect(result.failure == nil, "\(result.failure ?? "")")
        let brief = try #require(r.codex.read("brief_1"))
        #expect(brief.contains("> 28 | old 28") && brief.contains("> 30 | old 30") && brief.contains("  31 | old 31"))
        #expect(brief.contains("  10 | old 10") && !brief.contains("| line "), "only the base's code is shown")

        // A range from the left side to the right is numbered in two files: only the anchor's line is marked.
        let mixed = try await threadPR(base: base)
        let mixedGH = try ThreadGH(in: mixed)
        try mixedGH.thread(line: 32, startLine: 30, side: "RIGHT", startSide: "LEFT")
        _ = try await explain(mixed, gh: mixedGH)
        let mixedBrief = try #require(mixed.codex.read("brief_1"))
        #expect(mixedBrief.contains("> 32 | line 32") && !mixedBrief.contains("> 30 |"))

        // A left-side line on a file the base does not have: no code, not the head's in its place.
        let added = try await threadPR()
        let addedGH = try ThreadGH(in: added)
        try addedGH.thread(side: "LEFT")
        _ = try await explain(added, gh: addedGH)
        let addedBrief = try #require(added.codex.read("brief_1"))
        #expect(!addedBrief.contains("| line "), "the head's file is not shown for the base's line")
    }

    @Test func printsReasoningAndProposedFix() async throws {
        let r = try await threadPR()
        let ran = try await workbench(["explain-thread", "--pr", "12", "--thread", threadID], r, gh: try ThreadGH(in: r))
        #expect(ran.code == 0, "\(ran.stdout) \(ran.stderr)")
        #expect(ran.stdout.count >= 2, "a progress line comes first: \(ran.stdout)")
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data((ran.stdout.last ?? "").utf8)) as? [String: Any])
        #expect(object["reasoning"] as? String == "b can be 0 at line 30.")
        #expect(object["proposed_fix"] as? String == "Guard b == 0 before dividing.")
        #expect(object["pr"] as? Int == 12 && object["thread"] as? String == threadID)
        #expect(ran.stderr.isEmpty, "\(ran.stderr)")
    }

    @Test(arguments: [
        ("{\"reasoning\":\"A\",\"proposed_fix\":\"B\"}", true),
        ("```json\n{\"reasoning\":\"A\",\"proposed_fix\":\"B\"}\n```\n", true),
        ("\r\n{\"reasoning\":\"A\",\r\n\"proposed_fix\":\"B\"}\r\n", true),
        ("{\"reasoning\":\"A\"}", false),
        ("{\"reasoning\":\"A\",\"proposed_fix\":\"  \"}", false),
        ("{\"reasoning\":1,\"proposed_fix\":\"B\"}", false),
        ("The answer is {\"reasoning\":\"A\",\"proposed_fix\":\"B\"}", false),
        ("[\"A\",\"B\"]", false),
    ])
    func theAnswerIsAnObjectWithBothFields(text: String, accepted: Bool) {
        let parsed = ThreadExplain.answer(text)
        #expect((parsed != nil) == accepted, "\(text.debugDescription)")
        if accepted { #expect(parsed?.reasoning == "A" && parsed?.proposedFix == "B") }
    }

    @Test(arguments: [
        ("empty", "  \n\n"), ("missing", nil), ("no proposed_fix", #"{"reasoning":"why"}"#),
        ("empty reasoning", #"{"reasoning":"","proposed_fix":"fix"}"#), ("not JSON", "Here is what I think."),
    ])
    func emptyAnswerFails(label: String, answer: String?) async throws {
        let r = try await threadPR(answer: answer)
        let ran = try await workbench(["explain-thread", "--pr", "12", "--thread", threadID], r, gh: try ThreadGH(in: r))
        #expect(ran.code == 1, "\(label): \(ran.stdout) \(ran.stderr)")
        let lines = ran.stderr.split(separator: "\n")
        #expect(lines.count == 1 && lines[0].hasPrefix("workbench: failed: "), "\(label): \(ran.stderr)")
        #expect(ran.stdout.allSatisfy { !$0.hasPrefix("{") }, "\(label): no object on stdout: \(ran.stdout)")
        #expect(r.codex.runs == 1, "\(label): the agent did run")
    }

    @Test func refusals() async throws {
        let r = try await threadPR()
        struct Case {
            var label: String
            var args: [String]
            var gh: ThreadGH
            var code: Int32
            var said: String
        }
        let unknown = try ThreadGH(in: r)
        try unknown.put("thread.fail", "GraphQL: Could not resolve to a node with the global id of '\(threadID)' (node)\n")
        let notAThread = try ThreadGH(in: r)
        try notAThread.thread(type: "Issue")
        let closed = try ThreadGH(in: r, state: "CLOSED")
        let other = try ThreadGH(in: r)
        try other.thread(pr: 13)
        let down = try ThreadGH(in: r)
        try down.put("thread.fail", "HTTP 502: bad gateway\n")
        let fine = try ThreadGH(in: r)
        let args = ["--pr", "12", "--thread", threadID]
        let cases = [
            Case(label: "unknown thread", args: args, gh: unknown, code: 6, said: "no pull request review thread"),
            Case(label: "not a thread", args: args, gh: notAThread, code: 6, said: "no pull request review thread"),
            Case(label: "closed", args: args, gh: closed, code: 6, said: "it is not open"),
            Case(label: "other pull request", args: args, gh: other, code: 6, said: "is on pull request #13"),
            Case(label: "gh down", args: args, gh: down, code: 1, said: "HTTP 502"),
            Case(label: "no --pr", args: ["--thread", threadID], gh: fine, code: 2, said: "--pr"),
            Case(label: "no --thread", args: ["--pr", "12"], gh: fine, code: 2, said: "--thread"),
            Case(label: "bad --pr", args: ["--pr", "x", "--thread", threadID], gh: fine, code: 2, said: "'x'"),
            Case(label: "bad --thread", args: ["--pr", "12", "--thread", "../x"], gh: fine, code: 2, said: "'../x'"),
            Case(label: "extra", args: args + ["--again"], gh: fine, code: 2, said: "--again"),
        ]
        for c in cases {
            let ran = try await workbench(["explain-thread"] + c.args, r, gh: c.gh)
            let kind = ["1": "failed", "2": "usage", "6": "refused"][String(c.code)] ?? ""
            #expect(ran.code == c.code, "\(c.label): \(ran.stderr)")
            #expect(ran.stderr.hasPrefix("workbench: \(kind): ") && ran.stderr.contains(c.said), "\(c.label): \(ran.stderr)")
        }
        #expect(r.codex.runs == 0, "nothing was spawned")
        #expect(fine.calls.isEmpty, "bad usage reads nothing: \(fine.calls)")

        // A thread of the same number in another repository is another pull request too.
        let elsewhere = try ThreadGH(in: r)
        try elsewhere.thread(repository: "someone/else")
        await #expect(throws: ThreadExplainRefusal.self) {
            _ = try await r.fx.service.reviewThread(
                threadID, pr: 12, gh: elsewhere.runner, originURL: "git@github.com:o/n.git")
        }
        let same = try await r.fx.service.reviewThread(threadID, pr: 12, gh: elsewhere.runner, originURL: nil)
        #expect(same.pr == 12, "without a GitHub origin only the number is compared")
    }

    @Test func isReadOnly() async throws {
        let r = try await threadPR()
        let gh = try ThreadGH(in: r)
        let before = try await repoState(r)
        let events = try r.fx.events(r.id).count
        let ran = try await workbench(["explain-thread", "--pr", "12", "--thread", threadID], r, gh: gh)
        #expect(ran.code == 0, "\(ran.stderr)")
        #expect(try await repoState(r) == before, "branches, origin, HEAD, the working tree and the worktrees are as they were")
        #expect(try r.fx.events(r.id).count == events, "nothing is written to a thread's log")
        let calls = gh.calls
        #expect(calls.count == 2, "\(calls)")
        #expect(calls.allSatisfy { $0.hasPrefix("pr|view|") || $0.hasPrefix("api|graphql|") }, "gh only read: \(calls)")
        #expect(calls.allSatisfy { !$0.contains("mutation") }, "no GraphQL mutation (reply, resolve): \(calls)")
        let call = try #require(r.codex.calls.first)
        #expect(call.hasPrefix("exec -s read-only "), "\(call)")
    }
}
