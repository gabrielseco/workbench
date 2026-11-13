import Foundation

/// Makes an existing git repository a Workbench project, for a person who added its folder before it was one: what `workbench init` does
/// (`.workbench/config.toml` from the example, `.workbench/` kept out of `git status`), plus, on request, the goal agent that discusses and
/// drafts goals. It never overwrites: a config that is there stays byte for byte, and so does every agent it already names.
/// A call that fails removes what it created, so a retry starts from the folder as it was.
public enum ProjectSetup {
    /// Whether a folder still needs setting up: no `.workbench/`, or no config in it.
    public static func needsSetup(_ project: Project) -> Bool {
        !FileManager.default.fileExists(atPath: project.configURL.path)
    }

    /// What one setup did.
    public struct Report: Sendable, Equatable {
        /// The config was written now; false when one was already there and was left as it was.
        public var wroteConfig: Bool
        /// The goal agent the project has after setup: the one asked for, or the one the config already named. Nil is none.
        public var goalAgent: AgentProviderID?
        /// The config already named a goal agent, and it was kept instead of the one asked for.
        public var keptGoalAgent: Bool

        public init(wroteConfig: Bool, goalAgent: AgentProviderID?, keptGoalAgent: Bool) {
            (self.wroteConfig, self.goalAgent, self.keptGoalAgent) = (wroteConfig, goalAgent, keptGoalAgent)
        }
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case unsupported(String)
        case configDoesNotLoad(String)
        case notWritten(String)
        case goalAgent(String)
        case exclude(String)

        public var description: String {
            switch self {
            case .unsupported(let id): "'\(id)' cannot discuss or draft goals: use claude or codex."
            case .configDoesNotLoad(let why):
                "the existing .workbench/config.toml does not load, so it was left as it was: \(why)"
            case .notWritten(let why): ".workbench/config.toml could not be written: \(why)"
            case .goalAgent(let why): "the goal agent could not be set: \(why)"
            case .exclude(let why): ".workbench/ could not be kept out of `git status`: \(why)"
            }
        }
    }

    /// Sets the project up. `goalAgent` nil leaves goal drafting off (it can be named later); a config that already names one keeps it.
    @discardableResult
    public static func initialize(
        _ project: Project, goalAgent: AgentProviderID?, git: GitRunner, config text: String = Config.exampleTOML
    ) async throws -> Report {
        if let goalAgent, !AgentRole.goal.supportedProviders.contains(goalAgent) {
            throw Failure.unsupported(goalAgent.rawValue)
        }
        let fm = FileManager.default
        let madeDirectory = !fm.fileExists(atPath: project.workbenchDirectory.path)
        var wroteConfig = false
        // A config that was there, as it was, put back if a later step fails after the goal agent was added to it.
        var original: Data?
        func undo() {
            if wroteConfig { try? fm.removeItem(at: project.configURL) }
            if let original { try? original.write(to: project.configURL, options: .atomic) }
            if madeDirectory { try? fm.removeItem(at: project.workbenchDirectory) }
        }
        do {
            try fm.createDirectory(at: project.workbenchDirectory, withIntermediateDirectories: true)
            if !fm.fileExists(atPath: project.configURL.path) {
                // What is written must be a config Workbench itself accepts.
                do { _ = try Config.parse(text) } catch { throw Failure.notWritten("\(error)") }
                // Never over a config that appeared meanwhile.
                do { try Data(text.utf8).write(to: project.configURL, options: .withoutOverwriting) } catch {
                    throw Failure.notWritten(error.localizedDescription)
                }
                wroteConfig = true
            }
            let config: Config
            do { config = try Config.load(from: project.configURL) } catch { throw Failure.configDoesNotLoad("\(error)") }

            var report = Report(wroteConfig: wroteConfig, goalAgent: config.resolvedGoalAgent?.provider, keptGoalAgent: false)
            if let goalAgent {
                if report.goalAgent != nil {
                    report.keptGoalAgent = report.goalAgent != goalAgent
                } else {
                    if !wroteConfig { original = try? Data(contentsOf: project.configURL) }
                    do { try GoalAgentSetup.enable(provider: goalAgent, in: project) } catch {
                        throw Failure.goalAgent("\(error)")
                    }
                    report.goalAgent = goalAgent
                }
            }
            do { try await WorktreeManager(repoRoot: project.root, git: git).excludeWorkbench() } catch {
                throw Failure.exclude("\(error)")
            }
            return report
        } catch {
            undo()
            throw error
        }
    }
}
