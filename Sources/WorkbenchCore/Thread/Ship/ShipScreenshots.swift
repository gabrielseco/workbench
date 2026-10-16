import Foundation

/// What putting a shipped thread's screenshots in its pull request came to.
public enum ShipScreenshots: Sendable, Equatable {
    /// The latest verify step left no screenshot, or `--no-screenshots`: nothing to say.
    case none
    case attached(count: Int)
    /// Not attached, and why. The pull request is open either way.
    case skipped(String)
}

extension ThreadService {
    /// Most screenshots attached to one pull request.
    static let maxScreenshots = 20

    /// Puts the PNGs the latest verify step left in the pull request's description, through the `pr-shots`
    /// tool: each is copied to the place `pr-shots path <name>` names, then `pr-shots pr <number>` uploads the
    /// branch's screenshots and writes the `## Screenshots` section. Runs after the PR exists and never
    /// fails the ship: a missing tool or a failed upload is a note, and the next ship step stands.
    ///
    /// Only files the log recorded and that are still there as recorded are used, and the thread's own
    /// worktree is where `pr-shots` runs, so its project and branch names are the thread's.
    public func shipScreenshots(id: String, plan: ShipPlan, number: Int, tool: GitRunner?) async -> ShipScreenshots {
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

        do {
            for shot in shots {
                let name = String(shot.name.dropLast(".png".count))
                guard ScreenshotProof.isValidName(name) else {
                    return .skipped("\(shot.name) is not a usable screenshot name")
                }
                let found = try await tool.run(["path", name], in: plan.worktree)
                let destination = found.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                guard found.succeeded, destination.hasPrefix("/"), destination.hasSuffix(".png"),
                    !destination.contains("\n")
                else { return .skipped("`pr-shots path \(name)` gave no usable file name") }
                let target = URL(fileURLWithPath: destination)
                try FileManager.default.createDirectory(
                    at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.copyItem(at: threadDirectory.appendingPathComponent(shot.path), to: target)
            }
            let published = try await tool.run(["pr", String(number)], in: plan.worktree)
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
}
