import Foundation

/// What putting a shipped thread's screenshots in its pull request came to.
public enum ShipScreenshots: Sendable, Equatable {
    /// The latest turn's proof has no screenshot: nothing to say.
    case none
    /// `note` names the screenshots left out because the work changed after they were taken.
    case attached(count: Int, note: String? = nil)
    /// Not attached, and why. The pull request is open either way, and the screenshots are still in the thread.
    case skipped(String)
}

extension ThreadService {
    /// Most screenshots attached to one pull request.
    static let maxScreenshots = 20

    /// Puts the PNGs the latest turn's proof holds (the verifier's, or a verify step's) in the pull request's
    /// description, through the `pr-shots` tool. Runs after the PR exists and never fails the ship: a missing tool or a failed upload is a note,
    /// and `ship --screenshots` tries again.
    ///
    /// Three things keep it from publishing anything but what the proof recorded, where the person
    /// configured it:
    /// - Only files the log recorded and that are still there as recorded are used, copied into a fresh
    ///   directory that is the tool's whole screenshot folder (`PR_SHOTS_DIR`), so nothing older is uploaded.
    /// - The tool runs in the thread's worktree, where the model can write, and reads a `.pr-shots.json` from
    ///   there. One that differs from the project checkout's own is refused.
    /// - `GH_REPO` is dropped, so the tool's `gh pr view` and `gh pr edit` act on this repository's origin.
    public func shipScreenshots(id: String, worktree: URL, number: Int, tool: GitRunner?) async -> ShipScreenshots {
        let events = (try? EventLogReader.read(at: project.eventsURL(id)))?.events ?? []
        let state = ThreadState.derive(from: events, id: id)
        // The proof of the latest turn, whichever step left it: since the verifier replaced `verify_command` it is
        // the verifier's, and a thread from before that still has its verify step's.
        guard let set = Review.ProofSet(verify: state.review.verify, verifier: state.review.verifier),
            set.turn == state.lastTurn
        else { return .none }
        let threadDirectory = project.threadDirectory(id)
        let candidates = set.files.filter {
            $0.name.hasSuffix(".png") && !$0.name.contains("/") && $0.isAvailable(in: threadDirectory)
        }
        guard !candidates.isEmpty else { return .none }
        // A screenshot is about the work as it was when it was taken. A verifier rerun in the same turn keeps the
        // files it did not take again, so each file is checked against the work: what was committed since is a
        // different change, and files not committed are not shipped.
        let current = await ProofIdentity.committed(worktree: worktree, git: git)
        let stale = candidates.filter { ProofFreshness.of(recordedTree: $0.tree, current: current) == .stale }
        let shots = candidates.filter { shot in !stale.contains { $0.name == shot.name } }
        let staleNote = Self.staleNote(stale)
        if shots.isEmpty, let staleNote { return .skipped(staleNote) }
        guard let tool else {
            return .skipped(
                "\(shots.count) screenshot\(shots.count == 1 ? "" : "s") not attached: `pr-shots` is not on PATH "
                    + "(npm install -g /path/to/pr-shots)")
        }
        guard shots.count <= Self.maxScreenshots else {
            return .skipped("\(shots.count) screenshots is more than the \(Self.maxScreenshots) a pull request takes")
        }
        if let problem = Self.configProblem(worktree: worktree, checkout: project.root) { return .skipped(problem) }
        let at = shots.lazy.compactMap(\.commit).first.map { " at \($0.prefix(7))" } ?? ""
        // The pull request is what the screenshots go into, and a follow-up may have pushed to its branch since
        // this thread's worktree was left: what `origin` has now must be what was just checked. A pull request
        // this log recorded and an origin that cannot be read is not "fine": the uploader may reach GitHub where
        // this could not, so nothing is published until the branch can be seen.
        if let current, let branch = recordedPullRequestBranch(id: id) {
            guard let tip = try? await originBranchTip(branch) else {
                return .skipped(
                    "screenshots not attached: origin's \(branch) could not be read, so it is not known that the "
                        + "pull request is still at the work they were taken at. Run `workbench ship --screenshots` again")
            }
            if tip != current.commit {
                return .skipped(
                    "screenshots not attached: the pull request's branch is at \(tip.prefix(7)) and these screenshots "
                        + "were taken\(at) on this thread's \(current.commit.prefix(7)). Verify the branch's current "
                        + "work, then attach them from that thread")
            }
        }

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("wb-shots-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: folder) }
        var environment = tool.environment
        environment["GH_REPO"] = nil
        environment["PR_SHOTS_DIR"] = folder.path
        let runner = GitRunner(executable: tool.executable, environment: environment, timeout: tool.timeout)

        var copied: [String] = []
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
                copied.append(target.path)
            }
            // `pr-shots pr` leaves out a file it files under a longer branch name (`feat-a` vs `feat-a-b`) and
            // still exits 0. What it lists is what it would upload.
            let listed = try await runner.run(["list"], in: worktree)
            let included = Set(listed.stdout.split(separator: "\n").map { String($0) })
            guard listed.succeeded, copied.allSatisfy({ included.contains($0) }) else {
                return .skipped(
                    "`pr-shots` would leave some screenshots out, usually because another local branch's name "
                        + "starts with this one's; nothing was uploaded")
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
        return .attached(count: shots.count, note: staleNote)
    }

    /// What to say about screenshots left out because the work changed after they were taken, naming them.
    static func staleNote(_ stale: [ProofFile]) -> String? {
        guard !stale.isEmpty else { return nil }
        let at = stale.lazy.compactMap(\.commit).first.map { " at \($0.prefix(7))" } ?? ""
        let names = stale.map(\.name).joined(separator: ", ")
        return "\(names) not attached: taken\(at), and the work has changed since. "
            + "Run the verifier again, then `workbench ship --screenshots`"
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
