import Foundation
import WorkbenchCore

extension AppScenario {
    /// The rail's ten and Show more: fourteen finished threads (accepted, abandoned, discarded), and the oldest of all one that needs you,
    /// which the limit never hides.
    @MainActor func buildManyThreads(in fixture: AppFixture) async throws {
        try await fixture.addThread("a-old-review", approved: true, title: "Review the contract version bump")
        try fixture.append("a-old-review", .turnStarted, turn: 1, data: ["session_id": "s1"])
        try fixture.append("a-old-review", .turnEnded, turn: 1, data: ["result": "succeeded", "cost_usd": 0.8])
        try fixture.append("a-old-review", .checkStarted, turn: 1)
        try fixture.append(
            "a-old-review", .checkRan, turn: 1, data: ["result": "passed", "tests_passed": ["a"], "tests_failed": []])
        let decisions = ["accepted", "abandoned", "discarded"]
        for index in 1...14 {
            let id = String(format: "t%02d-finished", index)
            try await fixture.addThread(id, approved: true, title: "Finished thread number \(index)")
            try fixture.turn(id, 1, cost: 0.5)
            try fixture.decide(id, decisions[index % decisions.count])
        }
    }

    /// Whether `verify-app.sh start` cuts a worktree for the scenario's thread (it needs the repository and worktree files).
    var hasWorktree: Bool { self == .reviewChanges || self == .reviewBaseMoved }

    /// What the base gained after the thread's worktree was cut (`verify-app.sh start` commits it on `refs/remotes/origin/main`, as
    /// after a fetch, and leaves the project's own `main` where the thread started): one file the thread changed too, and a new one.
    var originMovedFiles: [String: String] {
        guard self == .reviewBaseMoved else { return [:] }
        return [
            "Sources/Invoices/List.swift":
                "struct List {\n    func page() -> [Invoice] { all.sorted(by: \\.date) }\n}\n",
            "Sources/Invoices/Sorting.swift": "extension Invoice {\n    static let byDate = \\Invoice.date\n}\n",
        ]
    }

    /// The projects of the rail, in order, by name (`rail` in the scenario's folder): `@PROJECT@` is the scenario's own project, a name
    /// with `!` is a folder that is gone, any other is a repository `verify-app.sh start` makes beside it. Empty: the rail is the project alone.
    var railNames: [String] { self == .projectRail ? ["api", "@PROJECT@", "mobile", "!docs", "web"] : [] }

    /// What the other projects of the rail hold (`rail-projects/<name>/threads` in the scenario's folder), by name: `api` two threads that need
    /// you, `mobile` a turn going, `web` a log that cannot be read. The scenario's own project and `docs` (a folder that is gone) hold none here.
    enum RailProjectKind: Equatable {
        case needsYou(Int)
        case running
        case brokenLog
    }

    var railProjectKinds: [String: RailProjectKind] {
        self == .projectRail ? ["api": .needsYou(2), "mobile": .running, "web": .brokenLog] : [:]
    }

    /// Writes the threads of the rail's other projects beside the scenario's own (`verify-app.sh start` copies each into its repository).
    @MainActor func writeRailProjects(into target: URL) async throws {
        for (name, kind) in railProjectKinds {
            let fixture = try await AppFixture(git: false)
            switch kind {
            case .needsYou(let count):
                for index in 0..<count {
                    try await fixture.addThread("n\(index)", approved: true, title: "Thread \(index + 1) of \(name)")
                    try fixture.turn("n\(index)", 1, cost: 0.8)
                }
            case .running:
                try await fixture.addThread("run", approved: true, title: "A turn going in \(name)")
                try fixture.append("run", .turnStarted, turn: 1, data: ["session_id": "s1"])
            case .brokenLog:
                let log = fixture.project.eventsURL("g-2026-10-28-bad")
                try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
                try "not an event\nnot one either\n".write(to: log, atomically: true, encoding: .utf8)
            }
            let destination = target.appendingPathComponent("rail-projects/\(name)/threads")
            let parent = destination.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: fixture.project.threadsDirectory, to: destination)
        }
    }

    /// The pull requests the stand-in `gh` says are merged (`merged-prs`, one number a line); the rest it says are open.
    var mergedPullRequests: [Int] { self == .prMerged ? [480] : [] }

    /// What a scenario ships beside its threads: its config, the pull requests `gh` says are merged, and its repository's files.
    func writeSideFiles(into target: URL) throws {
        if let config {
            try config.write(to: target.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        }
        if !railNames.isEmpty {
            try (railNames.joined(separator: "\n") + "\n").write(
                to: target.appendingPathComponent("rail"), atomically: true, encoding: .utf8)
        }
        if !mergedPullRequests.isEmpty {
            let lines = mergedPullRequests.map { "\($0)\n" }.joined()
            try lines.write(to: target.appendingPathComponent("merged-prs"), atomically: true, encoding: .utf8)
        }
        for (folder, contents) in [("repo", repoFiles), ("worktree", worktreeFiles), ("origin-moved", originMovedFiles)] {
            for (path, content) in contents {
                let url = target.appendingPathComponent(folder).appendingPathComponent(path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try content.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    /// Two shipped threads whose pull request review found things to fix: #480 has since been merged, #482 is still open.
    @MainActor func buildPRMerged(in fixture: AppFixture) async throws {
        let shipped = [("export-csv", "Export the invoice list as CSV", 480), ("invoice-pagination", Self.title, 482)]
        for (id, title, number) in shipped {
            try await fixture.addThread(id, approved: true, title: title)
            try fixture.turn(id, 1, cost: 1.2)
            try fixture.decide(id, "accepted")
            try fixture.ship(id, number: number)
            // Reviewed at the head the stand-in `gh` reports, so the open one's findings are current, not of an older commit.
            let round: [String: JSONValue] = [
                "round": 1, "pr": .int(number), "head_sha": "0123456789abcdef0123456789abcdef01234567",
            ]
            try fixture.append(id, .prReviewStarted, data: .object(round))
            var finished = round
            (finished["ok"], finished["verdict"]) = (true, "fix")
            try fixture.append(id, .prReviewFinished, data: .object(finished))
        }
    }
}
