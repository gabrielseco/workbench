import Foundation
import Testing

@testable import WorkbenchCore

private struct Out {
    var code: Int32?
    var stdout: [String]
    var stderr: String
    var text: String { (stdout + [stderr]).joined(separator: "\n") }
}

private func cli(_ arguments: [String], in fx: RunnerFixture, input: String? = nil) async throws -> Out {
    var spawn = SpawnRequest(
        executable: WorkbenchBinary.executable, arguments: arguments,
        environment: ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "USER": NSUserName(), "FAKE_CLAUDE": ""],
        workingDirectory: fx.repo, timeout: 120)
    spawn.snapshotInterval = 3600
    var lines: [String] = []
    var exit: ProcessExit?
    for await event in try ProcessRunner.start(spawn).events {
        if case .line(let line) = event { lines.append(line) }
        if case .exited(let e) = event { exit = e }
    }
    var code: Int32?
    if case .exited(let c)? = exit?.termination { code = c }
    return Out(code: code, stdout: lines, stderr: exit?.stderrTail ?? "")
}

private func object(_ lines: [String]) throws -> [String: Any] {
    #expect(lines.count == 1, "exactly one line of JSON on stdout: \(lines)")
    return try #require(JSONSerialization.jsonObject(with: Data((lines.first ?? "").utf8)) as? [String: Any])
}

private func documentedKeys(_ name: String) throws -> Set<String> {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("docs/spec/cli-json.md")
    let text = try String(contentsOf: url, encoding: .utf8)
    let line = try #require(text.split(separator: "\n").first { $0.hasPrefix("\(name) keys:") })
    return Set(line.dropFirst("\(name) keys:".count).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
}

@Suite struct CLIJSONTests {
    @Test func statusTakesAnIdOfAFinishedThreadAndAllListsEveryThread() async throws {
        let fx = try await RunnerFixture()
        let first = try await fx.approvedThread("first")
        _ = try await fx.runner(first).run(fx.options())
        try await fx.service.abandon(id: first)
        let second = try await fx.approvedThread("second")

        let one = try await cli(["status", first, "--json"], in: fx)
        #expect(one.code == 0, "\(one.text)")
        let o = try object(one.stdout)
        #expect(o["thread"] as? String == first)
        #expect(o["ended"] as? String == "abandoned")
        #expect(o["progress"] is NSNull)
        let log = try await cli(["log", first], in: fx)
        #expect(log.code == 0 && !log.stdout.isEmpty, "\(log.text)")

        let all = try await cli(["status", "--all", "--json"], in: fx)
        #expect(all.code == 0, "\(all.text)")
        let a = try object(all.stdout)
        let threads = try #require(a["threads"] as? [[String: Any]])
        #expect(Set(threads.compactMap { $0["thread"] as? String }) == [first, second])
        let ended = try #require(threads.first { $0["thread"] as? String == first })
        #expect(ended["ended"] as? String == "abandoned")
        #expect(ended["status"] as? String == "decided")
        let live = try #require(threads.first { $0["thread"] as? String == second })
        #expect(live["ended"] is NSNull)

        let text = try await cli(["status", "--all"], in: fx)
        #expect(text.stdout.count == 2, "\(text.text)")
        let both = try await cli(["status", "--all", first], in: fx)
        #expect(both.code != 0)
    }

    @Test func statusAndReviewAreOneDocumentedObjectEach() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        _ = try await fx.runner(id).run(fx.options())

        let status = try await cli(["status", "--json"], in: fx)
        #expect(status.code == 0 && status.stderr.isEmpty, "\(status.text)")
        let s = try object(status.stdout)
        #expect(Set(s.keys) == (try documentedKeys("status")))
        #expect(s["v"] as? Int == 1 && s["thread"] as? String == id && s["turns"] as? Int == 1)
        #expect((s["goal"] as? [String: Any])?["approval"] as? String == "approved")

        let review = try await cli(["review", id, "--json"], in: fx)
        #expect(review.code == 0 && review.stderr.isEmpty, "\(review.text)")
        let r = try object(review.stdout)
        #expect(Set(r.keys) == (try documentedKeys("review")))
        #expect(r["status"] as? String == "awaiting_review")
        let diff = try #require(r["diff"] as? [String: Any])
        #expect(diff["state"] as? String == "summary")
        let criteria = try #require(r["criteria"] as? [[String: Any]])
        #expect(criteria.count == 1)
        // Documented in docs/spec/cli-json.md: a proof that is not the recorded check is left to a person.
        #expect(Set(criteria[0].keys) == ["id", "text", "proof", "status", "commands", "note", "file"])
        #expect(criteria[0]["status"] as? String == "manual" && criteria[0]["commands"] is [Any])
        #expect((r["next"] as? String)?.contains("accept") == true)
    }

    @Test func logJSONIsTheStoredLinesAndNothingElse() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        _ = try await fx.runner(id).run(fx.options())

        let log = try await cli(["log", id, "--json"], in: fx)
        #expect(log.code == 0 && log.stderr.isEmpty)
        let stored = try String(contentsOf: fx.project.eventsURL(id), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        #expect(log.stdout == stored)

        let one = try await cli(["log", id, "--seq", "1", "--json"], in: fx)
        #expect(one.code == 0)
        #expect(one.stdout.count == 1, "one stored line")
        #expect(one.stdout.first == stored.first)

        // A raw `claude` line comes back byte for byte.
        let claudeSeq = try #require(
            try fx.events(id).first { $0.kind == .claude }?.seq)
        let raw = try await cli(["log", id, "--seq", String(claudeSeq), "--json"], in: fx)
        #expect(raw.stdout.count == 1 && raw.stdout.first == stored[claudeSeq - 1])
    }

    @Test func aHalfWrittenMultibyteTailHidesNothingBeforeIt() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        _ = try await fx.runner(id).run(fx.options())
        let url = fx.project.eventsURL(id)
        let stored = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
        // A writer that died inside a two-byte character.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0x7B, 0x22, 0xC3]))
        try handle.close()

        let log = try await cli(["log", id, "--json"], in: fx)
        #expect(log.code == 0)
        #expect(log.stdout == stored, "every whole event is still there")
    }

    @Test func anOptionValueThatReadsJSONIsNotTheFlag() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        let result = try await cli(["accept", id, "-m", "--json"], in: fx)
        // It reached `accept` (nothing to accept: refused), and was not read as an unsupported --json.
        #expect(result.code == 6, "\(result.text)")
        #expect(result.stderr.hasPrefix("workbench: refused: "))
    }

    @Test func everyFailureHasAKindAndOneCodeInTextAndJSON() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        // The active thread's goal, with its front matter gone.
        let broken = id
        try "no front matter here\n".write(to: fx.project.goalURL(id), atomically: true, encoding: .utf8)

        struct Case {
            var arguments: [String]
            var kind: String
            var code: Int32
        }
        let cases = [
            Case(arguments: ["status", "g-missing"], kind: "not-found", code: 7),
            Case(arguments: ["review", "g-missing", "--json"], kind: "not-found", code: 7),
            Case(arguments: ["log", "--bogus"], kind: "usage", code: 2),
            Case(arguments: ["accept", id, "--bogus"], kind: "usage", code: 2),
            Case(arguments: ["accept", id], kind: "refused", code: 6),
            Case(arguments: ["discard", id], kind: "refused", code: 6),
            Case(arguments: ["ship", "g-missing"], kind: "not-accepted", code: 10),
            Case(arguments: ["goal", "approve", broken], kind: "invalid-goal", code: 2),
            Case(arguments: ["frobnicate"], kind: "usage", code: 2),
        ]
        for item in cases {
            let (arguments, kind, code) = (item.arguments, item.kind, item.code)
            let result = try await cli(arguments, in: fx)
            #expect(result.code == code, "\(arguments): \(result.text)")
            if arguments.contains("--json") {
                #expect(result.stderr.isEmpty, "\(arguments): nothing on stderr")
                let error = try #require(try object(result.stdout)["error"] as? [String: Any])
                #expect(error["kind"] as? String == kind && error["code"] as? Int == Int(code))
                #expect((error["message"] as? String)?.isEmpty == false)
            } else {
                #expect(result.stderr.hasPrefix("workbench: \(kind): "), "\(arguments): \(result.stderr)")
            }
        }

        // `--json` on a command that has no JSON form is a usage error, not silently text.
        let unsupported = try await cli(["accept", "--json"], in: fx)
        #expect(unsupported.code == 2)
        #expect(try object(unsupported.stdout)["error"] != nil)
    }

    @Test func theSpecTableGivesEveryCodeOneMeaning() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/spec/exit-codes.md")
        // Only the table of meanings: the per-command tables under "By command" repeat codes on purpose.
        let whole = try String(contentsOf: url, encoding: .utf8)
        let text = String(whole.prefix(upTo: try #require(whole.range(of: "## By command")).lowerBound))
        let rows = text.split(separator: "\n").filter { $0.hasPrefix("| ") && !$0.hasPrefix("| Code") && !$0.contains("---") }
        let codes = rows.compactMap { row in
            Int(row.split(separator: "|")[0].trimmingCharacters(in: .whitespaces))
        }
        #expect(codes.count == Set(codes).count, "a code appears twice: \(codes)")
        #expect(Set(codes) == [0, 1, 2, 3, 4, 5, 6, 7, 10, 11, 12, 13, 14, 15])
    }
}
