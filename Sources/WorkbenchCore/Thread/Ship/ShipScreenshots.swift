import Foundation

/// What putting a shipped thread's screenshots in its pull request came to.
public enum ShipScreenshots: Sendable, Equatable {
    /// The latest verify step left no screenshot: nothing to say.
    case none
    case attached(count: Int)
    /// Not attached, and why. The pull request is open either way, and the screenshots are still in the thread.
    case skipped(String)
}

extension ThreadService {
    /// Most screenshots attached to one pull request.
    static let maxScreenshots = 20

    /// Puts the PNGs the latest verify step left in the pull request's description, through the `pr-shots`
    /// tool. Runs after the PR exists and never fails the ship: a missing tool or a failed upload is a note,
    /// and `ship --screenshots` tries again.
    ///
    /// Three things keep it from publishing anything but what the verify step recorded, where the person
    /// configured it:
    /// - Only files the log recorded and that are still there as recorded are used, copied into a fresh
    ///   directory that is the tool's whole screenshot folder (`PR_SHOTS_DIR`), so nothing older is uploaded.
    /// - The tool runs in the thread's worktree, where the model can write, and reads a `.pr-shots.json` from
    ///   there. One that differs from the project checkout's own is refused.
    /// - `GH_REPO` is dropped, so the tool's `gh pr view` and `gh pr edit` act on this repository's origin.
    public func shipScreenshots(id: String, worktree: URL, number: Int, tool: GitRunner?) async -> ShipScreenshots {
        let events = (try? EventLogReader.read(at: project.eventsURL(id)))?.events ?? []
        let state = ThreadState.derive(from: events, id: id)
        guard let verify = state.review.verify, verify.turn == state.lastTurn else { return .none }
        let threadDirectory = project.threadDirectory(id)
        let shots = verify.proof.filter {
            $0.name.hasSuffix(".png") && !$0.name.contains("/") && $0.isAvailable(in: threadDirectory)
        }
        guard !shots.isEmpty else { return .none }
        guard let tool else {
            return .skipped(
                "\(shots.count) screenshot\(shots.count == 1 ? "" : "s") not attached: `pr-shots` is not on PATH "
                    + "(npm install -g /path/to/pr-shots)")
        }
        guard shots.count <= Self.maxScreenshots else {
            return .skipped("\(shots.count) screenshots is more than the \(Self.maxScreenshots) a pull request takes")
        }
        if let problem = Self.configProblem(worktree: worktree, checkout: project.root) { return .skipped(problem) }

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("wb-shots-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: folder) }
        var environment = tool.environment
        environment["GH_REPO"] = nil
        environment["PR_SHOTS_DIR"] = folder.path
        let runner = GitRunner(executable: tool.executable, environment: environment, timeout: tool.timeout)

        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for shot in shots {
                let name = String(shot.name.dropLast(".png".count))
                guard ScreenshotProof.isValidName(name) else {
                    return .skipped("\(shot.name) is not a usable screenshot name")
                }
                let found = try await runner.run(["path", name], in: worktree)
                let destination = found.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                let target = URL(fileURLWithPath: destination).standardizedFileURL
                guard found.succeeded, destination.hasPrefix("/"), destination.hasSuffix(".png"),
                    target.path.hasPrefix(folder.path + "/")
                else { return .skipped("`pr-shots path \(name)` gave no usable file name") }
                try FileManager.default.createDirectory(
                    at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: threadDirectory.appendingPathComponent(shot.path), to: target)
            }
            let published = try await runner.run(["pr", String(number)], in: worktree)
            guard published.succeeded else {
                let why = (published.stderr.isEmpty ? published.stdout : published.stderr)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return .skipped("`pr-shots pr` failed: " + String(why.suffix(300)))
            }
        } catch GitError.timedOut(_, let seconds) {
            return .skipped("`pr-shots` did not finish in \(Int(seconds))s and was stopped")
        } catch {
            return .skipped("could not attach the screenshots: \(error)")
        }
        _ = try? await withLog(id) { log in
            try await log.append(
                .proofPublished,
                data: ["number": .int(number), "files": .array(shots.map { .string($0.name) }), "tool": "pr-shots"])
        }
        return .attached(count: shots.count)
    }

    /// `pr-shots` reads `.pr-shots.json` from where it runs, which is the worktree. A file there that the
    /// project checkout does not have, or has differently, could point uploads at a store the person never
    /// chose, so it stops the upload.
    static func configProblem(worktree: URL, checkout: URL) -> String? {
        let name = ".pr-shots.json"
        let mine = try? Data(contentsOf: worktree.appendingPathComponent(name))
        let theirs = try? Data(contentsOf: checkout.appendingPathComponent(name))
        guard mine != theirs else { return nil }
        return "screenshots not attached: the worktree's \(name) differs from the project's, and it decides where "
            + "they are uploaded. Review it, then run `workbench ship --screenshots`"
    }
}
