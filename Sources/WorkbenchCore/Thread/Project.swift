import Foundation

/// Where everything lives for one repository (docs/plan/P1-runner.md, "On disk").
///
///     <repo>/.workbench/
///       config.toml
///       threads/<id>/goal.md, events.jsonl, session.json, prompts/turn-N.md, checks/turn-N.log, runner.json
///       worktrees/<id>/
public struct Project: Sendable, Equatable {
    public let root: URL

    public init(root: URL) {
        self.root = root.resolvingSymlinksInPath()
    }

    public var workbenchDirectory: URL { root.appendingPathComponent(".workbench") }
    public var configURL: URL { workbenchDirectory.appendingPathComponent("config.toml") }
    public var threadsDirectory: URL { workbenchDirectory.appendingPathComponent("threads") }
    public var worktreesDirectory: URL { workbenchDirectory.appendingPathComponent("worktrees") }

    public func threadDirectory(_ id: String) -> URL { threadsDirectory.appendingPathComponent(id) }
    public func goalURL(_ id: String) -> URL { threadDirectory(id).appendingPathComponent("goal.md") }
    public func eventsURL(_ id: String) -> URL { threadDirectory(id).appendingPathComponent("events.jsonl") }
    public func sessionURL(_ id: String) -> URL { threadDirectory(id).appendingPathComponent("session.json") }
    public func runnerURL(_ id: String) -> URL { threadDirectory(id).appendingPathComponent("runner.json") }
    public func promptURL(_ id: String, turn: Int) -> URL {
        threadDirectory(id).appendingPathComponent("prompts/turn-\(turn).md")
    }

    /// Where a turn's check output is kept, relative to the thread directory (`output_ref` in the log).
    public static func checkOutputRef(turn: Int) -> String { "checks/turn-\(turn).log" }
    /// Where the setup command's output is kept, relative to the thread directory.
    public static func verifyOutputRef(turn: Int) -> String { "verify/turn-\(turn).log" }
    public static func proofRef(turn: Int) -> String { "proof/turn-\(turn)" }
    public func verifyOutputURL(_ id: String, turn: Int) -> URL {
        threadDirectory(id).appendingPathComponent(Self.verifyOutputRef(turn: turn))
    }
    /// Where the verify step of `turn` writes its evidence. Emptied before each run.
    public func proofDirectory(_ id: String, turn: Int) -> URL {
        threadDirectory(id).appendingPathComponent(Self.proofRef(turn: turn), isDirectory: true)
    }

    public static let setupOutputRef = "setup.log"
    public func setupOutputURL(_ id: String) -> URL {
        threadDirectory(id).appendingPathComponent(Self.setupOutputRef)
    }
    public func checkOutputURL(_ id: String, turn: Int) -> URL {
        threadDirectory(id).appendingPathComponent(Self.checkOutputRef(turn: turn))
    }

    /// The main checkout's top level, whether `directory` is in it or in one of its worktrees.
    public static func locate(from directory: URL, git: GitRunner) async throws -> Project {
        let result = try await git.run(
            ["rev-parse", "--path-format=absolute", "--git-common-dir"], in: directory)
        guard result.succeeded else { throw ProjectError.notAGitRepository(directory.path) }
        let common = URL(fileURLWithPath: result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        guard common.lastPathComponent == ".git" else { throw ProjectError.notAGitRepository(directory.path) }
        return Project(root: common.deletingLastPathComponent())
    }
}

public enum ProjectError: Error, Equatable, Sendable, CustomStringConvertible {
    case notAGitRepository(String)

    public var description: String {
        switch self {
        case .notAGitRepository(let path): "\(path) is not inside a git repository"
        }
    }
}
