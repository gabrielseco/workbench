import Foundation
import Testing

@testable import WorkbenchApp
@testable import WorkbenchCore

@MainActor private var keptFixtures: [AppFixture] = []

@MainActor @Suite struct HerdrStoreTests {
    private func store(
        found: Bool, opened: HerdrOpened = HerdrOpened(space: "sp1", alreadyOpen: false), error: Error? = nil
    ) async throws -> ProjectStore {
        let fixture = try await AppFixture()
        try await fixture.addThread("t1", approved: true)
        keptFixtures.append(fixture)
        let actions = GoalActions(
            herdrFound: { _ in found },
            openInHerdr: { _, _ in
                if let error { throw error }
                return opened
            })
        let store = ProjectStore(preferences: MemoryPreferences(projectPath: nil), actions: actions)
        #expect(await store.open(fixture.root))
        return store
    }

    @Test func theButtonIsOfferedOnlyWhereAHerdrWasFound() async throws {
        #expect(try await store(found: true).herdrFound)
        #expect(try await !store(found: false).herdrFound)
    }

    @Test func eachWayItOpenedSaysSo() async throws {
        let cases: [(HerdrOpened, String)] = [
            (HerdrOpened(space: "sp1", alreadyOpen: false), "Opened in Herdr."),
            (HerdrOpened(space: "sp1", alreadyOpen: true), "Herdr already had it open: brought forward."),
        ]
        for (opened, note) in cases {
            let store = try await store(found: true, opened: opened)
            await store.openInHerdr()
            #expect(store.actionNote == note && store.actionError == nil)
        }
    }

    @Test func anErrorIsTheErrorLineAndNothingElse() async throws {
        let failure = HerdrFailure(code: "timeout", message: "herdr-app did not answer within 10 seconds")
        let store = try await store(found: true, error: failure)
        await store.openInHerdr()
        #expect(store.actionError == "herdr-app did not answer within 10 seconds" && store.actionNote == nil)
        #expect(store.busy == nil && !store.runningHere)
    }

    /// A `herdr-app` stand-in that answers `ls`, `space.new` and `terminal.send` as the real one does, and writes down what it was asked.
    private func standIn(in dir: URL) throws -> HerdrOpener {
        let script = """
            #!/bin/sh
            echo $1 $2 $3 $4 >> "\(dir.path)/calls"
            case "$1 $2" in
              "ls ") printf '{\\n  "spaces": [],\\n  "recent": []\\n}\\n' ;;
              "do space.new")
                printf '%s' "$6" > "\(dir.path)/folder"; printf '{"space": "sp9", "tab": "tb9", "terminal": "t9"}\\n' ;;
              "do terminal.send") printf '%s' "$6" > "\(dir.path)/sent"; printf '{"ok": true}\\n' ;;
              *) printf '{"error": "unexpected"}\\n'; exit 1 ;;
            esac
            """
        let url = dir.appendingPathComponent("herdr-app")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return HerdrOpener(client: HerdrClient(executable: url, environment: ["PATH": "/usr/bin:/bin"])) {}
    }

    /// A draft thread on a repository with a commit, and a store whose "Run in Herdr" is the app's own with `opener` as Herdr.
    private func handoffStore(
        opener: HerdrOpener, timeoutOnly: Bool = true
    ) async throws -> (AppFixture, ProjectStore) {
        let fixture = try await AppFixture()
        keptFixtures.append(fixture)
        let commit = ["-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "--allow-empty", "-m", "base"]
        _ = try await GitRunner.discover().run(commit, in: fixture.root)
        try await fixture.addThread("t1", approved: false)
        if timeoutOnly {
            let url = fixture.project.goalURL("t1")
            let text = try String(contentsOf: url, encoding: .utf8)
            try text.replacingOccurrences(of: "budget_usd: 5", with: "spend_policy: timeout_only")
                .write(to: url, atomically: true, encoding: .utf8)
        }
        // Only how herdr-app is found differs from the app's action.
        let actions = GoalActions(runGoalInHerdr: { project, thread in
            try await GoalActions.runGoalInHerdr(project, thread, opener: opener)
        })
        let store = ProjectStore(preferences: MemoryPreferences(projectPath: nil), actions: actions)
        #expect(await store.open(fixture.root))
        return (fixture, store)
    }

    /// Nothing was approved or cut: the goal is still a draft, the log has neither event, and there is no worktree.
    private func expectUntouched(_ fixture: AppFixture) throws {
        let project = fixture.project
        let goal = try GoalFile.parse(String(contentsOf: project.goalURL("t1"), encoding: .utf8)).goal
        #expect(goal.approval != .approved, "the goal was approved")
        let events = try EventLogReader.read(at: project.eventsURL("t1")).events
        #expect(!events.contains { $0.kind == .goalApproved || $0.kind == .worktreeCreated })
        let worktree = WorktreeManager(repoRoot: project.root, git: try GitRunner.discover()).path(for: "t1")
        #expect(!FileManager.default.fileExists(atPath: worktree.path), "a worktree was cut")
    }

    @Test func unavailableHerdr() async throws {
        let herdrDir = FileManager.default.temporaryDirectory.appendingPathComponent("herdr-down-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: herdrDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: herdrDir) }
        // herdr-app is there, its window is not, and Herdr.app cannot be found to start it.
        let script = "#!/bin/sh\necho $1 $2 >> \"\(herdrDir.path)/calls\"\necho 'herdr-app: no Herdr window' >&2\nexit 2\n"
        let executable = herdrDir.appendingPathComponent("herdr-app")
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let opener = HerdrOpener(client: HerdrClient(executable: executable, environment: ["PATH": "/usr/bin:/bin"])) {
            throw GoalActions.HerdrNotFound(appMissing: true)
        }
        let (fixture, store) = try await handoffStore(opener: opener)

        await store.runGoalInHerdr()

        #expect(store.herdrHandoffOutcome == .unavailable("\(GoalActions.HerdrNotFound(appMissing: true))"))
        try expectUntouched(fixture)
        let calls = try String(contentsOf: herdrDir.appendingPathComponent("calls"), encoding: .utf8)
        #expect(calls.split(separator: "\n") == ["ls"])
    }

    @Test func aGoalWithADollarCapIsRefusedBeforeAnythingChanges() async throws {
        let herdrDir = FileManager.default.temporaryDirectory.appendingPathComponent("herdr-cap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: herdrDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: herdrDir) }
        let (fixture, store) = try await handoffStore(opener: try standIn(in: herdrDir), timeoutOnly: false)

        await store.runGoalInHerdr()

        guard case .failed(let why) = store.herdrHandoffOutcome else {
            Issue.record("a goal with budget_usd was handed to a session that cannot enforce it")
            return
        }
        #expect(why == "\(ThreadServiceError.budgetNeedsCap(provider: ThreadService.handoffAgent))")
        try expectUntouched(fixture)
        let calls = try String(contentsOf: herdrDir.appendingPathComponent("calls"), encoding: .utf8)
        #expect(calls.split(separator: "\n") == ["ls"], "Herdr was asked for more than whether its window is open")
    }

    @Test func runGoalInHerdr() async throws {
        let herdrDir = FileManager.default.temporaryDirectory.appendingPathComponent("herdr-run-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: herdrDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: herdrDir) }
        let (fixture, store) = try await handoffStore(opener: try standIn(in: herdrDir))
        let git = try GitRunner.discover()

        await store.runGoalInHerdr()

        #expect(store.herdrHandoffOutcome == .sent(space: "sp9") && store.actionError == nil && store.busy == nil)
        let project = fixture.project
        let events = try EventLogReader.read(at: project.eventsURL("t1")).events
        #expect(events.contains { $0.kind == .goalApproved }, "the goal was handed over without being approved")
        let cut = try #require(events.last { $0.kind == .worktreeCreated }, "no worktree.created for the handoff's worktree")
        let worktree = WorktreeManager(repoRoot: project.root, git: git).path(for: "t1")
        #expect(cut.data["path"]?.stringValue == worktree.path)
        // The session is pointed at the approved goal, copied into the worktree it works in.
        let copied = try String(
            contentsOf: worktree.appendingPathComponent(WorktreeManager.goalCopyPath), encoding: .utf8)
        #expect(copied == (try String(contentsOf: project.goalURL("t1"), encoding: .utf8)))
        #expect(try GoalFile.parse(copied).goal.approval == .approved)
        // Herdr made a space on that worktree, and Claude was typed into its terminal.
        let calls = try String(contentsOf: herdrDir.appendingPathComponent("calls"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        #expect(calls == ["ls", "ls", "do space.new --name t1", "do terminal.send --id t9"])
        let folder = try String(contentsOf: herdrDir.appendingPathComponent("folder"), encoding: .utf8)
        #expect(URL(fileURLWithPath: folder).resolvingSymlinksInPath().path == worktree.resolvingSymlinksInPath().path)
        // Claude, stopped at the approved goal's timeout.
        let sent = try String(contentsOf: herdrDir.appendingPathComponent("sent"), encoding: .utf8)
        #expect(sent == HerdrOpener.claudeCommand(turnTimeoutMin: 30) + "\n")
    }

    @Test func goalHandoffOutcome() async throws {
        let cases: [(Result<HerdrHandoff, Error>, HerdrHandoffOutcome)] = [
            (.success(HerdrHandoff(space: "sp1", alreadyOpen: false)), .sent(space: "sp1")),
            (.success(HerdrHandoff(space: "sp1", alreadyOpen: true)), .alreadyOpen(space: "sp1")),
            (.failure(GoalActions.HerdrNotFound()), .unavailable("\(GoalActions.HerdrNotFound())")),
            (.failure(GoalActions.HerdrNotFound(appMissing: true)),
                .unavailable("\(GoalActions.HerdrNotFound(appMissing: true))")),
            (.failure(HerdrFailure(code: "no_window", message: "Herdr's window is not open")),
                .unavailable("Herdr's window is not open")),
            (.failure(HerdrFailure(code: "launch_failed", message: "could not start /x")), .unavailable("could not start /x")),
            (.failure(HerdrFailure(code: "refused", message: "cannot start a terminal")), .failed("cannot start a terminal")),
            (.failure(HerdrFailure(code: "timeout", message: "herdr-app did not answer")), .failed("herdr-app did not answer")),
            (.failure(GoalActions.RefusalText("the goal still has placeholders")), .failed("the goal still has placeholders")),
        ]
        for (answer, expected) in cases {
            let fixture = try await AppFixture()
            try await fixture.addThread("t1", approved: true)
            keptFixtures.append(fixture)
            let actions = GoalActions(runGoalInHerdr: { _, _ in try answer.get() })
            let store = ProjectStore(preferences: MemoryPreferences(projectPath: nil), actions: actions)
            #expect(await store.open(fixture.root))
            #expect(store.herdrHandoffOutcome == nil, "an outcome before anything was handed over")
            await store.runGoalInHerdr()
            #expect(store.herdrHandoffOutcome == expected)
            #expect(store.busy == nil && !store.runningHere, "a handoff left the window busy or started a run of its own")
            // The outcome belongs to its thread: another one on screen does not show it.
            store.herdrHandoff?.scope = "elsewhere"
            #expect(store.herdrHandoffOutcome == nil)
        }
    }

    @Test func theRealGateShowsTheButtonOnlyForAHerdrThatIsThere() async throws {
        let fixture = try await AppFixture()
        keptFixtures.append(fixture)
        let project = fixture.project
        try FileManager.default.createDirectory(
            at: project.configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let stub = fixture.root.appendingPathComponent("stand-in.sh")
        try "#!/bin/sh\n".write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        func write(_ herdr: String) throws {
            try "herdr = \"\(herdr)\"\n[tools]\navailable = [\"Read\"]\n".write(
                to: project.configURL, atomically: true, encoding: .utf8)
        }
        try write(stub.path)
        #expect(GoalActions.core.herdrFound(project))
        // Named, but not there: no button (and no falling back to a herdr that is).
        try write(fixture.root.appendingPathComponent("gone").path)
        #expect(!GoalActions.core.herdrFound(project))
    }

    @Test func aConfigThatDoesNotLoadNeverFallsBackToTheRealHerdr() async throws {
        let fixture = try await AppFixture()
        keptFixtures.append(fixture)
        let project = fixture.project
        try FileManager.default.createDirectory(
            at: project.configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let marker = fixture.root.appendingPathComponent("stand-in-ran")
        let stub = fixture.root.appendingPathComponent("stand-in.sh")
        try "#!/bin/sh\ntouch '\(marker.path)'\n".write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        // The stand-in is named, but another key is wrong: the file does not load.
        try "herdr = \"\(stub.path)\"\nnot_a_key = 1\n[tools]\navailable = [\"Read\"]\n".write(
            to: project.configURL, atomically: true, encoding: .utf8)
        #expect(!GoalActions.core.herdrFound(project), "no button for a config that does not load")
        // Not reachable from the window, but the action itself still refuses to guess.
        do {
            _ = try await GoalActions.core.openInHerdr(project, "t1")
            Issue.record("a config that does not load still ran a herdr")
        } catch {
            #expect("\(error)".contains("does not load"))
        }
        #expect(!FileManager.default.fileExists(atPath: marker.path), "the stand-in ran")
        // With the config fixed, the same key finds the stand-in.
        try "herdr = \"\(stub.path)\"\n[tools]\navailable = [\"Read\"]\n".write(
            to: project.configURL, atomically: true, encoding: .utf8)
        #expect(try GoalActions.herdrExecutable(project)?.path == stub.path)
    }
}
