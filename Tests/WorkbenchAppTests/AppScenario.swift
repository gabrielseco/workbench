import Foundation
import WorkbenchCore

@testable import WorkbenchApp

/// The fixture projects `scripts/verify-app.sh` shows the app: one per state, committed under `Fixtures/app/<name>/threads/` (not
/// `.workbench/`, which `.gitignore` ignores). This is the one place that writes them, so a change to the log format is a change here,
/// and `FixtureScenarioTests` fails when a committed file differs from what this writes. To rewrite them:
///   WORKBENCH_WRITE_FIXTURES=Fixtures/app swift test --filter FixtureScenarioTests/writeTheScenarios
enum AppScenario: String, CaseIterable {
    case draft
    case goalWarning = "goal-warning"
    case goalApproved = "goal-approved"
    case goalLongRequest = "goal-long-request"
    case running
    case needsYou = "needs-you"
    case accepted
    case prOpen = "pr-open"
    case prFindings = "pr-findings"
    case prClean = "pr-clean"
    case cleaned
    case discarded
    case reviewChanges = "review-changes"
    case corrupt
    case noThread = "no-thread"
    case draftGoal = "draft-goal"
    case tasks
    case tasksEmpty = "tasks-empty"
    case taskThreads = "task-threads"
    case taskDone = "task-done"
    case threads
    case chat
    case chatGoal = "chat-goal"
    case chatReplying = "chat-replying"

    private static let title = "Paginate the contractor invoice list"

    /// The config a scenario ships, for the ones that show how proofs are judged against the tool set.
    var config: String? {
        switch self {
        case .goalWarning:
            "[tools]\navailable = [\"Read\", \"Bash\"]\nallowed = [\"Read\", \"Bash(swift test:*)\"]\n"
        case .goalLongRequest:
            "[tools]\navailable = [\"Read\", \"Bash\"]\nallowed = [\"Read\", \"Bash(pnpm run:*)\"]\n"
        case .prFindings:
            // Loads, so the fix round's confirm can read `[pr_review] max_rounds` and the budget from it.
            "[tools]\navailable = [\"Read\"]\n"
        case .goalApproved:
            // Shows the screen's "Also reads" line: the folder is only named on screen, nothing opens it.
            "read_also = [\"../expenses-backend\"]\n\n"
                + "[tools]\navailable = [\"Read\", \"Bash\"]\nallowed = [\"Read\", \"Bash(swift test:*)\"]\n"
        case .reviewChanges:
            // An editor that only writes down what it was asked to open; verify-app.sh puts its path in.
            // A config that does not load is ignored and the person's own global editor is used: it needs [tools].
            "editor = \"@EDITOR_STUB@\"\n\n[tools]\navailable = [\"Read\"]\nallowed = [\"Read\"]\n\n"
                + "[review]\nstages = [\"pr-review\", \"design\"]\n\n"
                + "[review.stage.design]\nskill = \"design.md\"\napplies_to = [\"Sources/**\"]\n"
        case .draftGoal:
            // The goal agent is the real Codex: this is the scenario that drafts a goal for real, from a request and screenshots.
            "[tools]\navailable = [\"Read\"]\nallowed = [\"Read\"]\n\n[agents.goal]\nprovider = \"codex\"\n"
        default: nil
        }
    }

    /// The files at the base commit of the scenario's repository, and the files the thread's worktree has on top of them. Only a scenario
    /// with both has a worktree, which `verify-app.sh start` makes (a fixture cannot commit one).
    var repoFiles: [String: String] {
        guard self == .reviewChanges else { return [:] }
        return [
            "Sources/Invoices/List.swift": "struct List {\n    func page() -> [Invoice] { all }\n}\n",
            "Sources/Invoices/Totals.swift": "struct Totals {\n    var sum = 0\n}\n",
            "README.md": "Invoices\n",
        ]
    }

    var worktreeFiles: [String: String] {
        guard self == .reviewChanges else { return [:] }
        return [
            "Sources/Invoices/List.swift":
                "struct List {\n    func page(_ n: Int, size: Int = 25) -> [Invoice] {\n"
                + "        Array(all.dropFirst(n * size).prefix(size))\n    }\n}\n",
            "Sources/Invoices/Totals.swift": "struct Totals {\n    var sum = 0\n    var pages = 0\n}\n",
            "Tests/InvoiceListTests.swift": "import Testing\n\n@Test func pagesAreTwentyFiveLong() {}\n",
        ]
    }

    /// Writes this scenario's thread(s) into a fresh fixture, as the real files.
    @MainActor func build(in fixture: AppFixture) async throws {
        let id = "invoice-pagination"
        switch self {
        case .draft:
            try await fixture.addThread(id, title: Self.title)
        case .goalWarning:
            // The fixture repository has no commit, so no verifier skill is at the base: the screenshot proof cannot be made.
            try await fixture.addThread(
                id, title: Self.title,
                proofs: ["`swift test` passes", "`./scripts/deploy.sh` exits 0", "screenshot: invoice-list"])
        case .goalLongRequest:
            // An approved goal whose request is long enough to be folded, with the `command:` proofs a drafted goal has.
            let request = (1...6).map {
                "Paragraph \($0): the seed script fails for one country because a call that used to answer 404 now answers 422, "
                    + "and the script must treat both as not found, the way it always treated the 404."
            }.joined(separator: " ")
            try await fixture.addThread(
                id, approved: true, title: Self.title,
                proofs: [
                    "command: pnpm run seed:onboarding --country=CZE --env=sandbox",
                    "test: seed-onboarding/treats a 422 like a 404",
                ], request: request)
        case .goalApproved:
            try await fixture.addThread(id, approved: true, title: Self.title, proofs: ["`swift test` passes"])
        case .running:
            try await fixture.addThread(id, approved: true, title: Self.title)
            try fixture.append(id, .turnStarted, turn: 1, data: ["session_id": "s1"])
            try fixture.activity(id, ["type": "text", "text": "Reading the invoice list and its tests"])
            try fixture.activity(id, ["type": "tool", "name": "Read", "summary": "Sources/Invoices/List.swift"])
            try fixture.activity(id, ["type": "tool", "name": "Edit", "summary": "Sources/Invoices/List.swift"])
            try fixture.activity(id, ["type": "permission_denied", "tool": "Bash", "input": "git push origin main"])
        case .needsYou, .reviewChanges:
            try await fixture.addThread(id, approved: true, title: Self.title)
            if self == .reviewChanges {
                // verify-app.sh start fills in the base commit and the worktree it makes.
                let created: JSONValue = [
                    "path": .string("@WORKTREE@"), "branch": .string("workbench/\(id)"), "base_commit": .string("@BASE@"),
                ]
                try fixture.append(id, .worktreeCreated, data: created)
            }
            try fixture.append(id, .turnStarted, turn: 1, data: ["session_id": "s1"])
            try fixture.activity(id, ["type": "tool", "name": "Edit", "summary": "Sources/Invoices/List.swift"])
            try fixture.activity(id, ["type": "tool", "name": "Write", "summary": "Tests/InvoiceListTests.swift"])
            try fixture.activity(id, ["type": "permission_denied", "tool": "Bash"])
            let denial: JSONValue = [["tool": "Bash", "input": "git push origin main"]]
            try fixture.append(
                id, .turnEnded, turn: 1,
                data: ["result": "succeeded", "cost_usd": 1.88, "permission_denials": 1, "denials": denial])
            try fixture.append(id, .checkStarted, turn: 1)
            try fixture.append(
                id, .checkRan, turn: 1, data: ["result": "passed", "tests_passed": ["a", "b", "c"], "tests_failed": []])
        case .accepted:
            try await fixture.addThread(id, approved: true, title: Self.title)
            try fixture.turn(id, 1, cost: 1.88)
            try fixture.decide(id, "accepted")
        case .prOpen:
            try await fixture.addThread(id, approved: true, title: Self.title)
            try fixture.turn(id, 1, cost: 1.88)
            try fixture.decide(id, "accepted")
            try fixture.ship(id, number: 482)
        case .prClean:
            // A shipped thread whose review is clean at the head the stand-in gh reports: Merge is the button, disabled while CI runs.
            try await fixture.addThread(id, approved: true, title: Self.title)
            try fixture.turn(id, 1, cost: 1.88)
            try fixture.decide(id, "accepted")
            try fixture.ship(id, number: 482)
            let round: [String: JSONValue] = ["round": 1, "pr": 482, "head_sha": "0123456789abcdef0123456789abcdef01234567"]
            try fixture.append(id, .prReviewStarted, data: .object(round))
            var finished = round
            finished["ok"] = true
            finished["verdict"] = "clean"
            try fixture.append(id, .prReviewFinished, data: .object(finished))
        case .prFindings:
            // A shipped thread whose pull request review found things to fix: the findings sheet offers a fix round.
            try await fixture.addThread(id, approved: true, title: Self.title)
            try fixture.turn(id, 1, cost: 1.88)
            try fixture.decide(id, "accepted")
            try fixture.ship(id, number: 482)
            let round: [String: JSONValue] = ["round": 1, "pr": 482, "head_sha": "abc123"]
            try fixture.append(id, .prReviewStarted, data: .object(round))
            var finished = round
            finished["ok"] = true
            finished["verdict"] = "fix"
            finished["findings_path"] = "pr-review/round-1/findings.md"
            try fixture.append(id, .prReviewFinished, data: .object(finished))
            let folder = fixture.project.threadDirectory(id).appendingPathComponent("pr-review/round-1")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try """
                - Sources/Invoices/List.swift: the page size is read from the request and never capped, so one call can ask for
                  every invoice. Cap it.
                - Tests/InvoiceListTests.swift: nothing covers an empty last page.

                VERDICT: FIX
                """.write(to: folder.appendingPathComponent("findings.md"), atomically: true, encoding: .utf8)
        case .cleaned:
            try await fixture.addThread(id, approved: true, title: Self.title)
            try fixture.turn(id, 1, cost: nil)
            try fixture.decide(id, "accepted")
            try fixture.ship(id, number: 482)
            try fixture.append(id, .branchRemoved, data: ["reason": "merged"])
        case .discarded:
            try await fixture.addThread(id, approved: true, title: Self.title)
            try fixture.append(id, .turnStarted, turn: 1, data: ["session_id": "s1", "provider": "codex"])
            try fixture.append(
                id, .agentActivity, turn: 1,
                data: ["provider": "codex", "type": "text", "text": "I'll check how the page handles the dialog"])
            try fixture.append(
                id, .agentActivity, turn: 1,
                data: ["provider": "codex", "type": "tool", "name": "shell", "summary": "git status --short"])
            try fixture.append(
                id, .turnEnded, turn: 1, data: ["result": "succeeded"], ts: "2026-10-28T11:04:12.000Z")
            try fixture.decide(id, "discarded")
        case .corrupt:
            try await fixture.addThread(id, approved: true, title: Self.title)
            try fixture.overwriteLog(id, with: "not json\n{broken\n")
        case .noThread, .draftGoal, .tasksEmpty:
            break
        case .chat, .chatGoal, .chatReplying:
            try writeChat(in: fixture, withGoal: self == .chatGoal, replying: self == .chatReplying)
        case .threads:
            // The thread list: a finished thread, one that needs you, one working and a draft, oldest first.
            try await fixture.addThread("trim-whitespace", approved: true, title: "Trim whitespace in invoice names")
            try fixture.turn("trim-whitespace", 1, cost: 0.92)
            try fixture.decide("trim-whitespace", "accepted")
            try fixture.ship("trim-whitespace", number: 478)
            try fixture.append("trim-whitespace", .branchRemoved, data: ["reason": "merged"])
            try await fixture.addThread("retry-uploads", approved: true, title: "Retry failed uploads with backoff")
            try fixture.turn("retry-uploads", 1, cost: 1.12)
            try fixture.decide("retry-uploads", "discarded")
            try await fixture.addThread(id, approved: true, title: Self.title)
            try fixture.append(id, .turnStarted, turn: 1, data: ["session_id": "s1"])
            try fixture.activity(id, ["type": "tool", "name": "Edit", "summary": "Sources/Invoices/List.swift"])
            try fixture.append(id, .turnEnded, turn: 1, data: ["result": "succeeded", "cost_usd": 1.88])
            try fixture.append(id, .checkStarted, turn: 1)
            try fixture.append(
                id, .checkRan, turn: 1, data: ["result": "passed", "tests_passed": ["a", "b"], "tests_failed": []])
            try await fixture.addThread("export-csv", title: "Export the invoice list as CSV")
        case .taskThreads:
            try await buildTaskThreads(in: fixture)
        case .taskDone:
            try await buildTaskDone(in: fixture)
        case .tasks:
            // The thread a task's run made, so that run's link can be pressed; the tasks themselves are written by `buildTasks`.
            try await fixture.addThread(id, approved: true, title: Self.title)
            try fixture.append(id, .turnStarted, turn: 1, data: ["session_id": "s1"])
            try fixture.append(id, .turnEnded, turn: 1, data: ["result": "succeeded"], ts: "2026-10-29T04:09:12.000Z")
            try await buildTasks(in: fixture)
        }
    }

    /// A chat thread (P22 slice 6): no goal file, no worktree. With a goal it is a chat that was made into one (6b), a goal thread now.
    @MainActor private func writeChat(in fixture: AppFixture, withGoal: Bool, replying: Bool = false) throws {
        let chat = "g-2026-10-28-upload-retries"
        try FileManager.default.createDirectory(at: fixture.project.threadDirectory(chat), withIntermediateDirectories: true)
        // No `repo`: it is a temporary path, and a committed fixture must be the same bytes on every run.
        try fixture.append(chat, .threadCreated, data: ["kind": "chat"])
        try fixture.append(chat, .chatMessage, data: ["role": "user", "text": "Could uploads retry with backoff?"])
        try fixture.append(chat, .chatMessage, data: ["role": "assistant", "text": "What should happen after the fifth try?"])
        try fixture.append(chat, .chatEnded, data: ["ok": true, "cost_usd": 0.01])
        if replying {
            // A second message whose turn has not ended: the agent is replying (no live process in a fixture, so it stays open).
            let text = "Give up after five tries, with a note in the log."
            try fixture.append(chat, .chatMessage, data: ["role": "user", "text": .string(text)])
        }
        guard withGoal else { return }
        try fixture.append(chat, .goalDraftStarted, data: ["provider": "codex", "from_chat": true])
        try fixture.append(chat, .goalSaved, data: ["status": "draft", "hash": .null])
        try fixture.append(chat, .goalDraftFinished, data: ["ok": true, "from_chat": true])
        let title = "Retry uploads with backoff"
        let text = try fixture.goalText(id: chat, approved: false, title: title, request: "Retry failed uploads.")
        try text.write(to: fixture.project.goalURL(chat), atomically: true, encoding: .utf8)
    }

    private static func parse(_ iso: String) -> Date {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return format.date(from: iso) ?? Date(timeIntervalSince1970: 0)
    }

    /// Seven tasks in the states the Tasks screen tells apart. Timestamps are fixed, so the committed files do not move.
    @MainActor private func buildTasks(in fixture: AppFixture) async throws {
        let project = fixture.project
        let files = FileManager.default
        func write(_ name: String, _ text: String) throws {
            let folder = project.taskFileURL(name).deletingLastPathComponent()
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
            try text.write(to: project.taskFileURL(name), atomically: true, encoding: .utf8)
        }
        let box = ClockBox()
        let library = TaskLibrary(project: project)
        func at(_ iso: String) { box.date = Self.parse(iso) }
        func run(
            _ name: String, _ start: String, outcome: TaskOutcome?, minutes: Int = 6, trigger: String = "tick",
            units: [String] = [],
            thread: String? = nil, reason: String? = nil, pr: String? = nil
        ) async throws {
            let writer = try await TaskRunLog(project: project, name: name).openWriter(now: { box.date })
            at(start)
            try await writer.append(.taskRunStarted, data: ["trigger": .string(trigger)])
            if let thread {
                try await writer.append(
                    .taskRunThread, data: ["thread": .string(thread), "units": .array(units.map { .string($0) }), "hash": "h"])
            }
            if let outcome {
                box.date = box.date.addingTimeInterval(TimeInterval(minutes * 60))
                var data: [String: JSONValue] = ["outcome": .string(outcome.rawValue), "units": .array(units.map { .string($0) })]
                if let reason { data["reason"] = .string(reason) }
                if let thread { data["thread"] = .string(thread) }
                if let pr { data["pr"] = .string(pr) }
                try await writer.append(.taskRunEnded, data: .object(data))
            }
            await writer.close()
        }
        func approve(_ name: String, _ start: String) async throws {
            at(start)
            try await library.approve(name, now: { box.date })
        }

        try write(
            "bump-contract-details",
            "---\nat: 04:00\ndays: weekdays\nbatch: 3\nfix: pr\nmax_open: 3\nbudget: 3.00\n---\nBump the next contracts.\n")
        try await approve("bump-contract-details", "2026-10-26T09:00:00.000Z")
        try await run(
            "bump-contract-details", "2026-10-28T04:00:02.000Z", outcome: .prOpened, minutes: 14, units: ["ROU", "TUR", "CZE"],
            thread: "invoice-pagination", pr: "https://github.com/example/remote-flows/pull/412")
        try await run(
            "bump-contract-details", "2026-10-29T04:00:03.000Z", outcome: .prOpened, minutes: 11, units: ["POL", "ESP"],
            thread: "bump-pol-esp", pr: "https://github.com/example/remote-flows/pull/415")
        try await run(
            "bump-contract-details", "2026-10-30T04:00:01.000Z", outcome: .skippedTooManyOpen, minutes: 0,
            reason: "3 of its own pull requests are open (max_open 3): #412, #415, #409")

        try write("sync-fixtures", "---\nevery: 7d\nfix: pr\nbudget: 2.00\ntimeout: 20\n---\nRefresh the fixtures.\n")
        try await approve("sync-fixtures", "2026-10-20T09:00:00.000Z")
        try await run("sync-fixtures", "2026-10-21T09:15:00.000Z", outcome: .nothingPending, minutes: 0)
        try await run(
            "sync-fixtures", "2026-10-28T09:15:00.000Z", outcome: .failed, minutes: 22, units: ["fixtures"],
            thread: "sync-fixtures-1",
            reason: "the check failed; the agent said: I regenerated the fixtures but two snapshots still differ; denied: "
                + "node -e require('./scripts/seed') | rm -rf build; check output: 2 failing / FAIL fixtures/countries.spec.ts / "
                + "expected 41 entries, got 40 (thread left for you: workbench ship or abandon)")

        try write("update-docs", "---\nat: 07:30\ndays: mon,thu\nfix: report\n---\nCheck the docs for stale pages.\n")
        try await approve("update-docs", "2026-10-22T09:00:00.000Z")
        try write(
            "update-docs",
            "---\nat: 07:30\ndays: mon,thu\nfix: report\nbudget: 1.00\n---\nCheck the docs for stale pages.\n")
        try await run(
            "update-docs", "2026-10-30T07:30:04.000Z", outcome: .staleApproval, minutes: 0,
            reason: "the task was edited after it was approved: workbench task approve update-docs")

        try write("weekly-report", "---\nevery: 30d\nfix: report\nbudget: 1.00\n---\nSummarise the week.\n")
        try await approve("weekly-report", "2026-10-02T09:00:00.000Z")
        try await run(
            "weekly-report", "2026-10-03T09:00:00.000Z", outcome: .budgetExceeded, minutes: 9, units: ["report"],
            reason: "the turn went over its budget of $1.00; the agent said: still reading the metrics")
        try await run(
            "weekly-report", "2026-10-26T09:10:00.000Z", outcome: .reported, minutes: 3, trigger: "manual", units: ["report"],
            reason: "would take 1 unit: report")

        try write("nightly-lint", "---\nat: 02:00\nfix: pr\nbudget: 1.50\n---\nFix lint warnings in one folder.\n")
        try await approve("nightly-lint", "2026-10-30T09:00:00.000Z")
        try await run("nightly-lint", "2026-10-31T02:00:05.000Z", outcome: .interrupted, minutes: 0, reason: "the process died")
        try await run("nightly-lint", "2026-11-01T02:00:02.000Z", outcome: nil, units: ["lint-3"], thread: "nightly-lint-3")

        try write(
            "cleanup-branches",
            "---\nat: 05:00\nfix: report\nlabels: [seed-preview, bot]\n---\nDelete the merged branches listed in branches.txt.\n")
        try write("broken-task", "---\nat: 06:00\ncolour: red\n---\nThis one does not load.\n")
    }

    /// Writes every scenario under `directory/<name>/`: its threads folder, or a `.gitkeep` for the one with none.
    @MainActor static func writeAll(into directory: URL) async throws {
        let files = FileManager.default
        for scenario in allCases {
            let fixture = try await AppFixture(git: false)
            try await scenario.build(in: fixture)
            let target = directory.appendingPathComponent(scenario.rawValue)
            try? files.removeItem(at: target)
            try files.createDirectory(at: target, withIntermediateDirectories: true)
            if let config = scenario.config {
                try config.write(to: target.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
            }
            for (folder, contents) in [("repo", scenario.repoFiles), ("worktree", scenario.worktreeFiles)] {
                for (path, content) in contents {
                    let url = target.appendingPathComponent(folder).appendingPathComponent(path)
                    try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try content.write(to: url, atomically: true, encoding: .utf8)
                }
            }
            let tasks = fixture.project.tasksDirectory
            if (try? files.contentsOfDirectory(atPath: tasks.path))?.isEmpty == false {
                try files.copyItem(at: tasks, to: target.appendingPathComponent("tasks"))
            }
            let threads = fixture.project.threadsDirectory
            if (try? files.contentsOfDirectory(atPath: threads.path))?.isEmpty == false {
                try files.copyItem(at: threads, to: target.appendingPathComponent("threads"))
            } else {
                try Data().write(to: target.appendingPathComponent(".gitkeep"))
            }
        }
    }
}

/// A clock a fixture moves by hand while it writes run logs.
private final class ClockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 0)
    var date: Date {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

extension AppScenario {
    /// The rail's grouping: two threads of your own, and the threads the tasks' runs made. Finished ones (shipped, discarded) are listed
    /// under their task; the one that needs you (`invoice-pagination`) stays in Threads.
    @MainActor private func buildTaskThreads(in fixture: AppFixture) async throws {
        try await fixture.addThread("export-csv", title: "Export the invoice list as CSV")
        // Over: your own (discarded), and two a task's runs made (shipped as #415, discarded).
        for (thread, title, decision) in [
            ("retry-uploads", "Retry failed uploads with backoff", "discarded"),
            ("bump-pol-esp", "bump-contract-details: POL, ESP", "accepted"), ("sync-fixtures-1", "sync-fixtures", "discarded"),
        ] {
            try await fixture.addThread(thread, approved: true, title: title)
            try fixture.turn(thread, 1, cost: 0.92)
            try fixture.decide(thread, decision)
        }
        try fixture.ship("bump-pol-esp", number: 415)
        let open = "invoice-pagination"
        try await fixture.addThread(open, approved: true, title: Self.title)
        try fixture.append(open, .turnStarted, turn: 1, data: ["session_id": "s1"])
        try fixture.append(open, .turnEnded, turn: 1, data: ["result": "succeeded"], ts: "2026-10-29T04:09:12.000Z")
        try await buildTasks(in: fixture)
    }
}

extension AppScenario {
    /// A task that acts through a tool and changes no file: its runs end `nothing-to-do`, and the thread each made was ended by the
    /// task itself after a succeeded turn and a passed check.
    @MainActor private func buildTaskDone(in fixture: AppFixture) async throws {
        let project = fixture.project
        let name = "update-contract-details-tracker"
        let folder = project.taskFileURL(name).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "---\nat: 21:00\ndays: weekdays\nfix: pr\nbudget: 3.00\n---\nRefresh the Linear issue.\n"
            .write(to: project.taskFileURL(name), atomically: true, encoding: .utf8)
        let box = ClockBox()
        box.date = Self.parse("2026-10-30T08:00:00.000Z")
        try await TaskLibrary(project: project).approve(name, now: { box.date })
        let thread = "update-tracker-1"
        try await fixture.addThread(thread, approved: true, title: name)
        try fixture.append(thread, .turnStarted, turn: 1, data: ["session_id": "s1"])
        try fixture.append(thread, .turnEnded, turn: 1, data: ["result": "succeeded", "cost_usd": 0.91])
        try fixture.append(thread, .checkStarted, turn: 1)
        try fixture.append(thread, .checkRan, turn: 1, data: ["result": "passed", "tests_passed": [], "tests_failed": []])
        try fixture.append(thread, .reviewDecision, data: ["decision": "abandoned", "by": "task"])
        let writer = try await TaskRunLog(project: project, name: name).openWriter(now: { box.date })
        box.date = Self.parse("2026-10-30T19:00:00.000Z")
        try await writer.append(.taskRunStarted, data: ["trigger": "tick"])
        try await writer.append(.taskRunThread, data: ["thread": .string(thread), "units": [], "hash": "h"])
        box.date = Self.parse("2026-10-30T19:01:24.000Z")
        let reason = "the agent changed nothing, so there is nothing to ship; the agent said: I updated PBYR-5087"
        try await writer.append(
            .taskRunEnded,
            data: ["outcome": "nothing-to-do", "units": [], "thread": .string(thread), "reason": .string(reason)])
        await writer.close()
    }
}
