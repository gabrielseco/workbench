import Foundation
import Testing

@testable import WorkbenchCore

/// A `gh` that records what it was asked and answers from files in its directory.
struct FakeGH {
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
            echo "${GH_REPO:-unset}" > "$d/repo"
            pwd -P > "$d/cwd"
            case "$1 $2" in
            "auth status") exit 0 ;;
            "pr checks")
              n=$(cat "$d/checks_n" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "$d/checks_n"
              from=$(cat "$d/checks_hang_from" 2>/dev/null || echo 99999)
              if [ "$n" -ge "$from" ]; then echo $$ > "$d/checks_pid"; exec sleep 60; fi
              if [ -f "$d/checks_hang" ]; then echo $$ > "$d/checks_pid"; exec sleep 60; fi
              if [ -f "$d/checks_fail" ]; then echo "boom" >&2; exit 1; fi
              f=""
              if [ -f "$d/checks_$n" ]; then f="$d/checks_$n"; elif [ -f "$d/checks_last" ]; then f="$d/checks_last"; fi
              if [ -z "$f" ]; then echo "no checks reported on the 'x' branch" >&2; exit 1; fi
              cat "$f"
              if grep -q pending "$f"; then exit 8; fi
              if grep -q '"fail"' "$f"; then exit 1; fi
              exit 0 ;;
            "pr list")
              f="$d/list"
              case "$*" in *"--json headRefName --limit"*)
                f="$d/list_open"
                if [ -f "$d/list_open_fail" ]; then cat "$d/list_open_fail" >&2; exit 1; fi ;;
              esac
              if [ -f "$f" ]; then cat "$f"; else echo '[]'; fi; exit 0 ;;
            "pr view")
              if [ -f "$d/view_fail" ]; then echo "view boom" >&2; exit 1; fi
              if [ -f "$d/view" ]; then cat "$d/view"; exit 0; fi
              exit 2 ;;
            "pr merge")
              if [ -f "$d/merge_fail" ]; then cat "$d/merge_fail" >&2; exit 1; fi
              if [ -f "$d/view_after_merge" ]; then cp "$d/view_after_merge" "$d/view"; fi
              exit 0 ;;
            "label create")
              if [ -f "$d/label_fail" ]; then cat "$d/label_fail" >&2; exit 1; fi
              exit 0 ;;
            "pr edit")
              case "$*" in *--add-label*)
                if [ -f "$d/addlabel_fail" ]; then cat "$d/addlabel_fail" >&2; exit 1; fi
                exit 0 ;;
              esac
              prev=""
              for a in "$@"; do
                if [ "$prev" = "--body-file" ]; then cp "$a" "$d/edit_body"; fi
                case "$a" in --title=*) echo "${a#--title=}" > "$d/edit_title" ;; esac
                prev="$a"
              done
              if [ -f "$d/edit_fail" ]; then cat "$d/edit_fail" >&2; exit 1; fi
              exit 0 ;;
            "pr create")
              prev=""
              for a in "$@"; do
                if [ "$prev" = "--body-file" ]; then
                  cp "$a" "$d/body"; (stat -c %a "$a" 2>/dev/null || stat -f %Lp "$a") > "$d/mode"; echo "$a" > "$d/bodypath"
                fi
                prev="$a"
              done
              if [ -f "$d/hang" ]; then exec sleep 60; fi
              if [ -f "$d/fail" ]; then cat "$d/fail" >&2; exit 1; fi
              if [ -f "$d/out" ]; then cat "$d/out"; else echo "https://github.com/o/r/pull/12"; fi
              exit 0 ;;
            "run view")
              job=""; prev=""
              for a in "$@"; do if [ "$prev" = "--job" ]; then job="$a"; fi; prev="$a"; done
              if [ -f "$d/runlog_$job" ]; then cat "$d/runlog_$job"; exit 0; fi
              echo "job $job: log not found" >&2; exit 1 ;;
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

@Suite(.processGate) struct ShipOpenPRTests {
    @Test func aRemoteTrackingBaseOpensThePRAgainstTheBranch() {
        func plan(base: String) -> ShipPlan {
            ShipPlan(
                id: "g", worktree: URL(fileURLWithPath: "/tmp"), branch: "workbench/g", remoteBranch: "workbench/g",
                base: base, head: "abc", origin: "o", remote: .absent)
        }
        #expect(plan(base: "origin/main").prBase == "main")
        #expect(plan(base: "origin/release/1.x").prBase == "release/1.x")
        #expect(plan(base: "main").prBase == "main")
    }

    @Test func aThreadCutFromARemoteTrackingBaseOpensItsPRAgainstTheBranch() async throws {
        let fx = try await RunnerFixture()
        let gh = try FakeGH(in: fx)
        _ = try await addOrigin(fx)
        _ = try await fx.git.run(["push", "-q", "origin", "main"], in: fx.repo)
        _ = try await fx.git.run(["fetch", "-q", "origin"], in: fx.repo)
        let id = try await fx.approvedThread(base: "origin/main")
        _ = try await fx.runner(id).run(fx.options())
        let worktree = fx.project.worktreesDirectory.appendingPathComponent(id)
        try "one\nhello\n".write(to: worktree.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try await fx.service.accept(id: id, message: "chore: work")
        _ = try await fx.service.shipPush(id: id, gh: gh.runner)

        _ = try await fx.service.shipOpenPR(id: id, gh: gh.runner)
        let create = try #require(gh.calls.first { $0.hasPrefix("pr create") })
        #expect(create.contains("--base main --head workbench/\(id) "), "got: \(create)")
        #expect(try fx.events(id).last?.data["base"]?.stringValue == "main")
    }

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

    @Test func aCutNumstatIsNeverPublishedAsTheWholeChange() {
        let whole = GitResult(status: 0, stdout: "3\t1\ta.txt\0", stderr: "")
        #expect(ThreadService.changes(from: whole).map(\.path) == ["a.txt"])
        var cut = whole
        cut.outputTruncated = true
        #expect(ThreadService.changes(from: cut).isEmpty, "a partial list would be stated as complete")
        #expect(ThreadService.changes(from: GitResult(status: 128, stdout: "3\t1\ta.txt\0", stderr: "")).isEmpty)
        #expect(ThreadService.changes(from: nil).isEmpty)
    }

    @Test func theOpenedPRFillsWhatChangedFromTheBranchesDiff() async throws {
        let fx = try await RunnerFixture()
        let gh = try FakeGH(in: fx)
        let templatePath = fx.repo.appendingPathComponent(".github/pull_request_template.md")
        try FileManager.default.createDirectory(
            at: templatePath.deletingLastPathComponent(), withIntermediateDirectories: true)
        let template = """
            ## Summary

            <!-- what -->

            ## Why

            <!-- why -->

            ## What changed

            <details>
            <summary>Files and behaviour</summary>

            <!-- per area -->

            </details>

            ## Testing

            - [ ] checked
            """
        try (template + "\n").write(to: templatePath, atomically: true, encoding: .utf8)
        _ = try await fx.git.run(["add", "-A"], in: fx.repo)
        _ = try await fx.git.run(["commit", "-q", "-m", "template"], in: fx.repo)

        let id = try await fx.approvedThread()
        _ = try await fx.runner(id).run(fx.options())
        let worktree = fx.project.worktreesDirectory.appendingPathComponent(id)
        try "one\nhello\n".write(to: worktree.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "new\n".write(to: worktree.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        try await fx.service.accept(id: id, message: "chore: work")
        _ = try await addOrigin(fx)
        _ = try await fx.service.shipPush(id: id, gh: gh.runner)

        _ = try await fx.service.shipOpenPR(id: id, gh: gh.runner)
        let body = try #require(gh.read("body"))
        #expect(body.contains("## What changed\n\n<details>\n<summary>Files and behaviour (2 files"), "\(body)")
        #expect(body.contains("- `a.txt`  +") && body.contains("- `b.txt`  +1 \u{2212}0"), "\(body)")
        #expect(!body.contains("<!-- per area -->"))
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

    @Test func anExistingPRKeepsItsOwnHeadAndAnUnusableRecordIsRefusedNotDuplicated() async throws {
        let fx = try await RunnerFixture()
        let gh = try FakeGH(in: fx)
        let id = try await pushedThread(fx, gh.runner).id
        let other = String(repeating: "b", count: 40)
        try gh.put(
            "list",
            "[{\"number\": 7, \"url\": \"https://user:tok@github.com/o/r/pull/7\", \"headRefName\": \"workbench/\(id)\"}]")
        let bad = await openRefusal { try await fx.service.shipOpenPR(id: id, gh: gh.runner) }
        guard case .ghFailed? = bad else {
            Issue.record("got \(String(describing: bad))")
            return
        }
        #expect(gh.count("pr create") == 0)
        #expect(!(try fx.events(id).contains { $0.kind == .prOpened }))

        try gh.put(
            "list",
            "[{\"number\": 7, \"url\": \"https://github.com/o/r/pull/7\", \"headRefName\": \"workbench/\(id)\", "
                + "\"baseRefName\": \"main\", \"headRefOid\": \"\(other)\"}]")
        _ = try await fx.service.shipOpenPR(id: id, gh: gh.runner)
        #expect(try fx.events(id).last?.data["head_sha"]?.stringValue == other)
    }

    @Test func otherCredentialShapesAreRemovedFromGHsMessages() {
        let samples = [
            "Authorization: Bearer ghp_abcdefgh12345678", "token ghp_abcdefgh12345678 rejected",
            "GET https://api.github.com/x?access_token=hunter2hunter2&per_page=1", "github_pat_11ABCDEFG0abcdefgh",
        ]
        for sample in samples {
            let clean = ThreadService.withoutCredentials(sample)
            #expect(!clean.contains("ghp_") && !clean.contains("hunter2") && !clean.contains("github_pat_"), "\(clean)")
        }
        let env = ThreadService.withoutCredentials(
            "denied for letmein-12345", environment: ["GH_TOKEN": "letmein-12345", "HOME": "/x"])
        #expect(env == "denied for <redacted>")
    }

    @Test func aPathInTheTemplateAndTheCheckOutcomeReachTheBodyCorrectly() async throws {
        let fx = try await RunnerFixture()
        let gh = try FakeGH(in: fx)
        let templatePath = fx.repo.appendingPathComponent(".github/pull_request_template.md")
        try FileManager.default.createDirectory(
            at: templatePath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "## Summary\n\n## Rollout\n\nRun /Users/alice/private/deploy.sh\n".write(
            to: templatePath, atomically: true, encoding: .utf8)
        _ = try await fx.git.run(["add", "-A"], in: fx.repo)
        _ = try await fx.git.run(["commit", "-q", "-m", "template"], in: fx.repo)
        let (id, _) = try await acceptedThread(fx)
        let log = try EventLogWriter.open(at: fx.project.eventsURL(id))
        _ = try await log.append(.checkStarted, turn: 1, data: ["command": "scripts/check.sh"])
        _ = try await log.append(
            .checkRan, turn: 1,
            data: ["result": "passed", "exit_code": 0, "duration_ms": 4000, "output_ref": "checks/turn-1.log"])
        await log.close()
        _ = try await addOrigin(fx)
        _ = try await fx.service.shipPush(id: id, gh: gh.runner)

        _ = try await fx.service.shipOpenPR(id: id, gh: gh.runner)
        let body = try #require(gh.read("body"))
        #expect(!body.contains("/Users/alice"))
        #expect(body.contains("Check: passed (exit 0, 4s)"), "\(body)")
    }

    @Test func credentialsPastedIntoTheGoalOrTemplateAreNotPublishedAndGHRepoIsDropped() async throws {
        let fx = try await RunnerFixture()
        let gh = try FakeGH(in: fx)
        let (id, _) = try await acceptedThread(fx)
        _ = try await addOrigin(fx)
        _ = try await fx.service.shipPush(id: id, gh: gh.runner)
        let goal = fx.project.goalURL(id)
        let text = try String(contentsOf: goal, encoding: .utf8)
        try text.replacingOccurrences(of: "title: work", with: "title: fix with ghp_abcdefgh12345678")
            .replacingOccurrences(of: "Add a greeting to a.txt.", with: "Use Authorization: Bearer abc123def456")
            .write(to: goal, atomically: true, encoding: .utf8)

        let withRepo = GitRunner(
            executable: gh.runner.executable, environment: gh.runner.environment.merging(["GH_REPO": "evil/repo"]) { $1 },
            timeout: 10)
        _ = try await fx.service.shipOpenPR(id: id, gh: withRepo)
        let published = (gh.read("body") ?? "") + gh.calls.joined(separator: "\n")
        #expect(!published.contains("ghp_abcdefgh") && !published.contains("abc123def456"), "\(published)")
        #expect(gh.read("repo")?.trimmingCharacters(in: .whitespacesAndNewlines) == "unset")
    }

    @Test func aTemplateTooLargeToReadWholeIsRefusedNotTruncated() async throws {
        let fx = try await RunnerFixture()
        let gh = try FakeGH(in: fx)
        let path = fx.repo.appendingPathComponent(".github/pull_request_template.md")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ("## Summary\n\n" + String(repeating: "x", count: 70_000) + "\n## Rollout\n").write(
            to: path, atomically: true, encoding: .utf8)
        _ = try await fx.git.run(["add", "-A"], in: fx.repo)
        _ = try await fx.git.run(["commit", "-q", "-m", "template"], in: fx.repo)
        let id = try await pushedThread(fx, gh.runner).id

        let error = await openRefusal { try await fx.service.shipOpenPR(id: id, gh: gh.runner) }
        guard case .gitFailed(let why)? = error else {
            Issue.record("got \(String(describing: error))")
            return
        }
        #expect(why.contains("64 KiB"), "\(why)")
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

@Suite(.processGate) struct ShipOpenPRJudgeTests {
    @Test func theLatestJudgesConcernsAreInThePRBody() async throws {
        let fx = try await RunnerFixture()
        let gh = try FakeGH(in: fx)
        let pushed = try await pushedThread(fx, gh.runner)
        let log = try EventLogWriter.open(at: fx.project.eventsURL(pushed.id))
        let turn = ThreadStore(project: fx.project).state(of: pushed.id).lastTurn
        _ = try await log.append(
            .judgeRan, turn: turn,
            data: [
                "ok": true, "criteria": [], "concerns": ["No test calls visibleItems with the order."],
            ])
        await log.close()

        _ = try await fx.service.shipOpenPR(id: pushed.id, gh: gh.runner)
        let body = try #require(gh.read("body"))
        #expect(body.contains("### Judge concerns") && body.contains("- No test calls visibleItems with the order."))
    }
}

@Suite(.processGate) struct ShipOpenPRLabelTests {
    @Test func labelsAreCreatedThenAddedToTheNewPullRequestAndNothingElseGetsThem() async throws {
        let fx = try await RunnerFixture()
        let gh = try FakeGH(in: fx)
        let id = try await pushedThread(fx, gh.runner).id

        let result = try await fx.service.shipOpenPR(id: id, gh: gh.runner, labels: ["seed-preview", "-odd"])
        #expect(result.outcome == .created && result.labelNote == nil)
        let labelCalls = gh.calls.filter { $0.hasPrefix("label ") || ($0.hasPrefix("pr edit") && $0.contains("--add-label")) }
        #expect(
            labelCalls == [
                "label create --force -- seed-preview", "pr edit 12 --add-label=seed-preview",
                "label create --force -- -odd", "pr edit 12 --add-label=-odd",
            ], "got: \(labelCalls)")
        // Created after the pull request, so the PR never waits on them.
        let created = try #require(gh.calls.firstIndex { $0.hasPrefix("pr create") })
        let labelled = try #require(gh.calls.firstIndex { $0.hasPrefix("label") })
        #expect(created < labelled)

        // No labels asked for: no label call. A pull request that already existed is not touched either.
        let other = try await RunnerFixture()
        let ghOther = try FakeGH(in: other)
        let plain = try await pushedThread(other, ghOther.runner).id
        _ = try await other.service.shipOpenPR(id: plain, gh: ghOther.runner)
        #expect(ghOther.calls.allSatisfy { !$0.hasPrefix("label") && !$0.contains("--add-label") })
    }

    @Test func everyFailedLabelIsNamedEvenWhenAllFiveAreLongAndTheirErrorsToo() async throws {
        let fx = try await RunnerFixture()
        let gh = try FakeGH(in: fx)
        let id = try await pushedThread(fx, gh.runner).id
        try gh.put("label_fail", String(repeating: "boom ", count: 60) + "\n")
        let labels = (1...5).map { String(repeating: "\($0)", count: 50) }
        let note = try #require(
            try await fx.service.shipOpenPR(id: id, gh: gh.runner, labels: labels).labelNote)
        for label in labels { #expect(note.contains("label '\(label)'"), "\(note)") }
        #expect(!note.contains("\n") && note.count < 1_200)
    }

    @Test func anExistingPullRequestIsNotLabelled() async throws {
        let fx = try await RunnerFixture()
        let gh = try FakeGH(in: fx)
        let id = try await pushedThread(fx, gh.runner).id
        try gh.put(
            "list",
            #"[{"number": 7, "url": "https://github.com/o/r/pull/7", "headRefName": "workbench/\#(id)", "baseRefName": "main"}]"#)
        let result = try await fx.service.shipOpenPR(id: id, gh: gh.runner, labels: ["a"])
        #expect(result.outcome == .existing && result.labelNote == nil)
        #expect(gh.calls.allSatisfy { !$0.hasPrefix("label") && !$0.contains("--add-label") })
    }

    @Test func aLabelThatFailsIsNotedAndTheRecordedPullRequestStands() async throws {
        let fx = try await RunnerFixture()
        let gh = try FakeGH(in: fx)
        let id = try await pushedThread(fx, gh.runner).id
        try gh.put("label_fail", "HTTP 403: Resource not accessible\nsecond line\n")

        let result = try await fx.service.shipOpenPR(id: id, gh: gh.runner, labels: ["a", "b"])
        #expect(result.outcome == .created && result.number == 12)
        let note = try #require(result.labelNote)
        #expect(!note.contains("\n") && note.contains("label 'a'") && note.contains("label 'b'") && note.contains("HTTP 403"))
        #expect(!note.contains("second line") && note.count <= 600, "\(note)")
        // A failed create stops that label's add, and the next label is still tried.
        #expect(gh.count("label create") == 2 && gh.calls.allSatisfy { !$0.contains("--add-label") })
        #expect(try fx.events(id).last?.kind == .prOpened)

        // Adding fails but creating works: the label is still named.
        let other = try await RunnerFixture()
        let ghOther = try FakeGH(in: other)
        let second = try await pushedThread(other, ghOther.runner).id
        try ghOther.put("addlabel_fail", "label not found\n")
        let again = try await other.service.shipOpenPR(id: second, gh: ghOther.runner, labels: ["x"])
        #expect(again.labelNote?.contains("label 'x': label not found") == true)
        #expect(try other.events(second).last?.kind == .prOpened)
    }
}
