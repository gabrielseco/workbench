import Foundation

public enum SeriesError: Error, Equatable, Sendable, CustomStringConvertible {
    case notFound(String)
    case invalid([SeriesProblem])
    case writeFailed(String)

    public var description: String {
        switch self {
        case .notFound(let what): "no series at \(what)"
        case .invalid(let problems): problems.map(\.description).joined(separator: "\n")
        case .writeFailed(let why): "the approval was not recorded: \(why)"
        }
    }
}

/// A series as it is on disk now: the file, its goal files, and what approval binds.
public struct LoadedSeries: Sendable {
    public var definition: SeriesDefinition
    /// The goal file each step names, by step number, as `goal new --from` reads it.
    public var goals: [Int: GoalCopy]
    public var goalTexts: [Int: String]
    /// The step's project with `~/` expanded.
    public var projects: [Int: URL]
    public var hash: String
}

public enum SeriesApproval {
    static let version = "workbench-series-v1"

    public enum State: Equatable, Sendable {
        case never
        /// The series file or one of its goal files changed since it was approved.
        case stale
        case approved
    }

    /// Made from what the series means: every step's keys, the budget and the words of every goal file. Whitespace-only edits
    /// do not revoke an approval; a change to a step, a goal's word or the budget does.
    public static func hash(_ definition: SeriesDefinition, goalTexts: [Int: String]) -> String {
        var fields = [version, "budget=\(definition.budgetUSD.map { NSDecimalNumber(decimal: $0).stringValue } ?? "none")"]
        for step in definition.steps {
            let base: String
            switch step.base {
            case .branch(let branch): base = branch ?? "default"
            case .after(let n): base = "after \(n)"
            }
            let env = step.env.map { pair in
                switch pair.value {
                case .literal(let v): "\(pair.name)=\(v)"
                case .stepBranch(let n): "\(pair.name)=step:\(n)"
                }
            }
            fields.append(
                "step\(step.number) project=\(step.project) goal=\(step.goal) base=\(base) "
                    + "after=\(step.after.map(String.init).joined(separator: ",")) env=\(env.joined(separator: ","))")
            let text = GoalHash.canonicalBody(goalTexts[step.number] ?? "")
            let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
            fields.append("goal\(step.number)_sha256=" + digest)
        }
        return SHA256.hash(data: Data(fields.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static func state(approvedHash: String?, currentHash: String) -> State {
        guard let approvedHash else { return .never }
        return approvedHash == currentHash ? .approved : .stale
    }
}

public struct SeriesLibrary: Sendable {
    public let project: Project
    /// Read for `~/`; a test points it elsewhere.
    public var home: URL

    public init(project: Project, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.project = project
        self.home = home
    }

    public func names() -> [String] {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: project.seriesDirectory.path)) ?? []
        return entries.filter {
            SafeNames.isThreadID($0)
                && FileManager.default.fileExists(atPath: project.seriesDirectory($0).appendingPathComponent("series.md").path)
        }.sorted()
    }

    func expand(_ path: String) -> URL {
        path.hasPrefix("~/")
            ? home.appendingPathComponent(String(path.dropFirst(2))) : URL(fileURLWithPath: path)
    }

    private func read(_ url: URL, limit: Int) throws -> String {
        // Not a link: a goal file that points outside the series folder is refused, not followed.
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw SeriesError.invalid([SeriesProblem(line: nil, message: "\(url.lastPathComponent) is not a regular file")])
        }
        guard (values.fileSize ?? 0) <= limit, let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw SeriesError.invalid([SeriesProblem(line: nil, message: "\(url.lastPathComponent) is too large or not text")])
        }
        return text
    }

    /// Parses the file and checks, all at once, everything a run would trip on: the projects, the goal files, and a stacked step's
    /// parent being in the same project.
    public func load(_ name: String) throws -> LoadedSeries {
        let directory = project.seriesDirectory(name)
        let file = directory.appendingPathComponent("series.md")
        guard SafeNames.isThreadID(name), FileManager.default.fileExists(atPath: file.path) else {
            throw SeriesError.notFound(".workbench/series/\(name)/series.md")
        }
        let text = try read(directory.appendingPathComponent("series.md"), limit: 64 << 10)
        let parsed: SeriesDefinition?
        var problems: [SeriesProblem]
        do { (parsed, problems) = try SeriesDefinition.parseAll(text, name: name) } catch let error as SeriesParseError {
            throw SeriesError.invalid(error.problems)
        }
        guard let definition = parsed else { throw SeriesError.invalid(problems) }

        var goals: [Int: GoalCopy] = [:]
        var texts: [Int: String] = [:]
        var projects: [Int: URL] = [:]
        for step in definition.steps {
            func add(_ message: String) {
                problems.append(SeriesProblem(line: nil, message: "step \(step.number): \(message)"))
            }
            let root = expand(step.project).standardizedFileURL
            projects[step.number] = root
            var isDirectory: ObjCBool = false
            if !FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) || !isDirectory.boolValue {
                add("project \(step.project) is not a folder")
            } else if !FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path) {
                add("project \(step.project) is not a git checkout")
            } else if !FileManager.default.fileExists(atPath: root.appendingPathComponent(".workbench/config.toml").path) {
                add("project \(step.project) is not a Workbench project (no .workbench/config.toml; run `workbench init`)")
            }
            if case .after(let parent) = step.base, let parentRoot = projects[parent], parentRoot != root {
                add("'base: after \(parent)' needs the same project as step \(parent); 'after: \(parent)' only waits for it")
            }
            do {
                let goalText = try read(directory.appendingPathComponent(step.goal), limit: ThreadService.copySourceLimit)
                texts[step.number] = goalText
                goals[step.number] = try ThreadService.goalCopy(copying: directory.appendingPathComponent(step.goal))
            } catch let error as SeriesError {
                if case .invalid(let inner) = error { inner.forEach { add("goal \(step.goal): \($0.message)") } }
            } catch {
                add("goal \(step.goal): \(error)")
            }
        }
        guard problems.isEmpty else { throw SeriesError.invalid(problems) }
        return LoadedSeries(
            definition: definition, goals: goals, goalTexts: texts, projects: projects,
            hash: SeriesApproval.hash(definition, goalTexts: texts))
    }

    private func approvalURL(_ name: String) -> URL { project.seriesDirectory(name).appendingPathComponent("approval.json") }

    public func approvedHash(_ name: String) -> String? {
        // Bounded and only a regular file: a FIFO or a huge file there reads as "not approved", it does not hang.
        guard let text = try? read(approvalURL(name), limit: 4 << 10),
            let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        else { return nil }
        return object["hash"] as? String
    }

    public func state(_ loaded: LoadedSeries) -> SeriesApproval.State {
        SeriesApproval.state(approvedHash: approvedHash(loaded.definition.name), currentHash: loaded.hash)
    }

    /// Records the approval of what is on disk now. Returns the hash.
    public func approve(_ name: String, now: Date = Date()) throws -> String {
        let loaded = try load(name)
        let object: [String: Any] = ["hash": loaded.hash, "approved_at": ISO8601DateFormatter().string(from: now)]
        do {
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            try data.write(to: approvalURL(name), options: .atomic)
        } catch { throw SeriesError.writeFailed("\(error)") }
        return loaded.hash
    }
}
