import Foundation
import Testing

@testable import WorkbenchCore

/// A `gh` that records what it was asked and answers from files in its directory.
private struct FakeGH {
    let dir: URL
    let runner: GitRunner

    init(in fx: RunnerFixture, token: String = "ghp_tok_secret") throws {
        dir = fx.repo.deletingLastPathComponent().appendingPathComponent("gh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("gh")
        try """
            #!/bin/sh
            d="$GH_FAKE_DIR"
            echo "$@" >> "$d/calls"
            case "$1 $2" in
            "auth status") exit 0 ;;
            "pr list") if [ -f "$d/list" ]; then cat "$d/list"; else echo '[]'; fi; exit 0 ;;
            "pr create")
              prev=""
              for a in "$@"; do
                if [ "$prev" = "--body-file" ]; then
                  cp "$a" "$d/body"; stat -f %Lp "$a" > "$d/mode"; echo "$a" > "$d/bodypath"
                fi
                prev="$a"
              done
              if [ -f "$d/hang" ]; then exec sleep 60; fi
              if [ -f "$d/fail" ]; then cat "$d/fail" >&2; exit 1; fi
              if [ -f "$d/out" ]; then cat "$d/out"; else echo "https://github.com/o/r/pull/12"; fi
              exit 0 ;;
            esac
            exit 2
            """.write(to: script, atomically: true, encoding: .utf8)
        chmod(script.path, 0o755)
        runner = GitRunner(
            executable: script, environment: ["PATH": "/usr/bin:/bin", "GH_FAKE_DIR": dir.path, "GITHUB_TOKEN": token],
            timeout: 10)
    }

    func put(_ name: String, _ text: String) throws {
        try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func read(_ name: String) -> String? { try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8) }

    var calls: [String] { (read("calls") ?? "").split(separator: "\n").map(String.init) }
    func count(_ verb: String) -> Int { calls.filter { $0.hasPrefix(verb) }.count }
}

private struct Pushed {
    var id: String
    var worktree: URL
}

private func pushedThread(_ fx: RunnerFixture, _ gh: GitRunner) async throws -> Pushed {
    let (id, worktree) = try await acceptedThread(fx)
    _ = try await addOrigin(fx)
    _ = try await fx.service.shipPush(id: id, gh: gh)
    return Pushed(id: id, worktree: worktree)
}

private func openRefusal(_ body: () async throws -> ShipPRResult) async -> ShipError? {
    do {
        _ = try await body()
        return nil
    } catch { return error as? ShipError }
}

@Suite struct ShipOpenPRTests {
    @Test func aPushedThreadGetsOnePRAndARecord() async throws {
        let fx = try await RunnerFixture()
        let gh = try FakeGH(in: fx)
        let pushed = try await pushedThread(fx, gh.runner)
        let (id, worktree) = (pushed.id, pushed.worktree)
        let head = try await shipOut(["rev-parse", "HEAD"], worktree, fx)

        let result = try await fx.service.shipOpenPR(id: id, gh: gh.runner)
        #expect(result.outcome == .created && result.number == 12)
        #expect(result.url == "https://github.com/o/r/pull/12")
        #expect(gh.count("pr create") == 1)
        let create = try #require(gh.calls.first { $0.hasPrefix("pr create") })
        #expect(create.contains("--base main --head workbench/\(id) --title=work --body-file "))

        let event = try #require(try fx.events(id).last)
        #expect(event.kind == .prOpened)
        #expect(event.data["url"]?.stringValue == "https://github.com/o/r/pull/12")
        #expect(event.data["number"]?.intValue == 12)
        #expect(event.data["branch"]?.stringValue == "workbench/\(id)")
        #expect(event.data["base"]?.stringValue == "main")
        #expect(event.data["head_sha"]?.stringValue == head)
        #expect(try fx.contents(id).isHealthy)
    }

    @Test func theBodyIsTheBuilderWithTheTemplateFromTheBaseCommit() async throws {
        let fx = try await RunnerFixture()
        let gh = try FakeGH(in: fx)
        let templatePath = fx.repo.appendingPathComponent(".github/pull_request_template.md")
        try FileManager.default.createDirectory(
            at: templatePath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "## Summary\n\n## Rollout\n\nFrom the base.\n".write(to: templatePath, atomically: true, encoding: .utf8)
        _ = try await fx.git.run(["add", "-A"], in: fx.repo)
        _ = try await fx.git.run(["commit", "-q", "-m", "template"], in: fx.repo)

        let id = try await fx.approvedThread()
        _ = try await fx.runner(id).run(fx.options())
        let worktree = fx.project.worktreesDirectory.appendingPathComponent(id)
        try "## Summary\n\n## Rollout\n\nEdited by the run.\n".write(
            to: worktree.appendingPathComponent(".github/pull_request_template.md"), atomically: true, encoding: .utf8)
        try await fx.service.accept(id: id, message: "chore: work")
        _ = try await addOrigin(fx)
        _ = try await fx.service.shipPush(id: id, gh: gh.runner)

        _ = try await fx.service.shipOpenPR(id: id, gh: gh.runner)
        let body = try #require(gh.read("body"))
        let goal = try GoalFile.parse(String(contentsOf: fx.project.goalURL(id), encoding: .utf8)).goal
        let expected = PRBodyBuilder.build(
            goal: goal, check: ThreadStore(project: fx.project).state(of: id).review.check,
            template: "## Summary\n\n## Rollout\n\nFrom the base.\n")
        #expect(body == expected.body)
        #expect(body.contains("From the base.") && !body.contains("Edited by the run."))
        #expect(gh.read("mode")?.trimmingCharacters(in: .whitespacesAndNewlines) == "600")
        let path = try #require(gh.read("bodypath")?.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(!FileManager.default.fileExists(atPath: path), "the body file is removed")
        #expect(!path.hasPrefix(fx.repo.path), "and was never inside the repository")
    }

    @Test func anExistingPRIsRecordedOnceAndNeverDuplicated() async throws {
        let fx = try await RunnerFixture()
        let gh = try FakeGH(in: fx)
        let id = try await pushedThread(fx, gh.runner).id
        try gh.put(
            "list",
            """
            [{"number": 7, "url": "https://github.com/o/r/pull/7", "headRefName": "workbench/\(id)", "baseRefName": "main"},
             {"number": 9, "url": "https://github.com/o/r/pull/9", "headRefName": "other", "baseRefName": "main"}]
            """)

        let result = try await fx.service.shipOpenPR(id: id, gh: gh.runner)
        #expect(result.outcome == .existing && result.number == 7)
        #expect(gh.count("pr create") == 0)
        #expect(try fx.events(id).filter { $0.kind == .prOpened }.count == 1)

        // Once recorded, a second call is refused as shipped and asks `gh` for nothing.
        let before = gh.calls.count
        let again = await openRefusal { try await fx.service.shipOpenPR(id: id, gh: gh.runner) }
        #expect(again == .alreadyShipped(url: "https://github.com/o/r/pull/7"))
        #expect(gh.calls.count == before, "preflight refused before `gh` was asked anything")
        #expect(gh.count("pr create") == 0)
    }

    @Test func aBranchThatIsNotOnOriginAtTheTipIsRefusedWithoutCreating() async throws {
        let fx = try await RunnerFixture()
        let gh = try FakeGH(in: fx)
        let (id, _) = try await acceptedThread(fx)
        let bare = try await addOrigin(fx)

        let absent = await openRefusal { try await fx.service.shipOpenPR(id: id, gh: gh.runner) }
        guard case .notPushed? = absent else {
            Issue.record("got \(String(describing: absent))")
            return
        }

        let mainSHA = try await shipOut(["rev-parse", "main"], fx.repo, fx)
        _ = try await fx.git.run(["push", "-q", bare.path, "\(mainSHA):refs/heads/workbench/\(id)"], in: fx.repo)
        let behind = await openRefusal { try await fx.service.shipOpenPR(id: id, gh: gh.runner) }
        guard case .notPushed? = behind else {
            Issue.record("got \(String(describing: behind))")
            return
        }
        #expect(gh.count("pr create") == 0)
        #expect(!(try fx.events(id).contains { $0.kind == .prOpened }))
    }

    @Test func aFailingOrHungCreateRecordsNothingAndCanBeRepeated() async throws {
        let fx = try await RunnerFixture()
        let gh = try FakeGH(in: fx)
        let id = try await pushedThread(fx, gh.runner).id

        try gh.put("fail", "GraphQL: not allowed (https://user:sekret@api.github.com/graphql)\n")
        let failed = await openRefusal { try await fx.service.shipOpenPR(id: id, gh: gh.runner) }
        guard case .ghFailed(let why)? = failed else {
            Issue.record("got \(String(describing: failed))")
            return
        }
        #expect(why.contains("not allowed") && !why.contains("sekret"), "\(why)")
        #expect(!(try fx.events(id).contains { $0.kind == .prOpened }))

        try FileManager.default.removeItem(at: gh.dir.appendingPathComponent("fail"))
        try gh.put("hang", "")
        let hung = await openRefusal { try await fx.service.shipOpenPR(id: id, gh: gh.runner, timeout: 2) }
        guard case .gitFailed(let text)? = hung else {
            Issue.record("got \(String(describing: hung))")
            return
        }
        #expect(text.contains("did not finish"), "\(text)")
        #expect(!(try fx.events(id).contains { $0.kind == .prOpened }))

        try FileManager.default.removeItem(at: gh.dir.appendingPathComponent("hang"))
        #expect(try await fx.service.shipOpenPR(id: id, gh: gh.runner).outcome == .created)
    }

    @Test func onlyAPlainPullRequestURLIsAccepted() async throws {
        #expect(ThreadService.pullRequest(from: "https://github.com/o/r/pull/12")?.number == 12)
        let bad = [
            "http://github.com/o/r/pull/12", "https://user:tok@github.com/o/r/pull/12", "https://github.com/o/r/pull/12/files",
            "https://github.com/o/r/pull/x", "https://github.com/o/r/issues/12", "https://github.com/o/r/pull/12?a=b",
            "https://github.com/o/r/pull/012", "https://github.com:444/o/r/pull/12", "", "created!",
        ]
        for text in bad { #expect(ThreadService.pullRequest(from: text) == nil, "\(text)") }

        let fx = try await RunnerFixture()
        let gh = try FakeGH(in: fx)
        let id = try await pushedThread(fx, gh.runner).id
        try gh.put("out", "https://user:tok@github.com/o/r/pull/12\n")
        let error = await openRefusal { try await fx.service.shipOpenPR(id: id, gh: gh.runner) }
        guard case .ghFailed? = error else {
            Issue.record("got \(String(describing: error))")
            return
        }
        #expect(!(try fx.events(id).contains { $0.kind == .prOpened }))
    }

    @Test func noTokenAndNoMachinePathReachesTheLogTheArgvOrTheBody() async throws {
        let fx = try await RunnerFixture()
        let gh = try FakeGH(in: fx, token: "ghp_never_in_the_log")
        let id = try await pushedThread(fx, gh.runner).id
        let goal = fx.project.goalURL(id)
        let text = try String(contentsOf: goal, encoding: .utf8)
        try text.replacingOccurrences(of: "cat a.txt", with: "cat /Users/someone/secret/a.txt")
            .write(to: goal, atomically: true, encoding: .utf8)

        let result = try await fx.service.shipOpenPR(id: id, gh: gh.runner)
        #expect(result.outcome == .created)
        let log = try String(contentsOf: fx.project.eventsURL(id), encoding: .utf8)
        let seen = [log, gh.calls.joined(separator: "\n"), gh.read("body") ?? ""]
        for blob in seen {
            #expect(!blob.contains("ghp_never_in_the_log"))
            #expect(!blob.contains("/Users/someone"))
        }
        #expect(!(gh.read("body") ?? "").contains(fx.repo.path))
    }
}
