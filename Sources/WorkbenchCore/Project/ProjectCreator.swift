import Foundation

public struct NewProjectRequest: Sendable {
    public var name: String
    /// The directory the project goes in; the project is `<parent>/<name>`.
    public var parent: URL
    /// Files or directories copied into `vendor/<basename>/`.
    public var seeds: [URL]
    /// Allow `parent` to be inside another git repository.
    public var nested: Bool
    public var defaults: GlobalConfig

    public init(name: String, parent: URL, seeds: [URL] = [], nested: Bool = false, defaults: GlobalConfig = GlobalConfig()) {
        self.name = name
        self.parent = parent
        self.seeds = seeds
        self.nested = nested
        self.defaults = defaults
    }
}

public enum NewProjectError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidName(String)
    case targetNotEmpty(String)
    case targetNotADirectory(String)
    case insideRepository(target: String, repository: String)
    case seedNotFound(String)
    case seedHasSymlink(String)
    case seedUnreadable(String)
    case seedOverlapsTarget(seed: String, target: String)
    case seedCollision(String)
    case seedTooLarge(String)
    case gitFailed(command: String, stderr: String)

    public var description: String {
        switch self {
        case .invalidName(let n):
            "'\(n)' is not a usable project name (one path component of letters, digits, '.', '_' and '-', "
                + "starting with a letter or digit)"
        case .targetNotEmpty(let p): "\(p) exists and is not empty; nothing was written"
        case .targetNotADirectory(let p): "\(p) exists and is not a directory"
        case .insideRepository(let target, let repo):
            "\(target) would be inside the git repository at \(repo). Pass --nested if that is what you want"
        case .seedNotFound(let p): "seed \(p) does not exist"
        case .seedHasSymlink(let p):
            "seed \(p) is or contains a symbolic link; Claude cannot follow it out of the worktree, so seeds "
                + "are copied and links are refused"
        case .seedUnreadable(let p): "seed \(p) cannot be read"
        case .seedOverlapsTarget(let seed, let target):
            "seed \(seed) and the new project \(target) overlap; the copy would include its own output"
        case .seedCollision(let n): "two seeds would both land in vendor/\(n)"
        case .seedTooLarge(let p):
            "seed \(p) is larger than \(ProjectCreator.maxSeedFiles) files or \(ProjectCreator.maxSeedBytes >> 20) MB"
        case .gitFailed(let command, let stderr):
            "git \(command) failed: \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
    }
}

/// Creates a repository that is ready to be a Workbench project: `main` with one empty commit, optional
/// `vendor/` seeds in a second commit, `.workbench/config.toml`, and `.workbench/` kept out of `git status`.
/// Runs only `git` and file copies; no Claude and no thread.
public struct ProjectCreator: Sendable {
    public static let maxSeedFiles = 10_000
    public static let maxSeedBytes = 100 << 20

    let git: GitRunner
    /// Called with each file or directory about to be copied. A test seam: it makes a copy fail midway.
    var beforeCopy: (@Sendable (URL) throws -> Void)?

    public init(git: GitRunner) { self.git = git }

    /// A seed, checked: what to copy and where.
    struct PlannedSeed {
        var source: URL
        var name: String
        var files: Int
    }

    /// Checks everything that can be checked without writing, then creates the project. Returns its root.
    @discardableResult
    public func create(_ request: NewProjectRequest) async throws -> URL {
        guard SafeNames.isProjectName(request.name) else { throw NewProjectError.invalidName(request.name) }
        let seeds = try Self.plan(seeds: request.seeds)

        let fm = FileManager.default
        let parent = request.parent.standardizedFileURL
        let target = parent.appendingPathComponent(request.name)

        // A link in the target's place would let the project land somewhere the checks below never looked.
        if Self.isSymlink(target) { throw NewProjectError.targetNotADirectory(target.path) }

        let resolvedTarget = Self.resolved(target)
        for seed in seeds {
            let source = Self.resolved(seed.source).path
            let place = resolvedTarget.path
            if place == source || place.hasPrefix(source + "/") || source.hasPrefix(place + "/") {
                throw NewProjectError.seedOverlapsTarget(seed: seed.source.path, target: target.path)
            }
        }

        var targetExisted = false
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: target.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw NewProjectError.targetNotADirectory(target.path) }
            let contents = (try? fm.contentsOfDirectory(atPath: target.path)) ?? ["?"]
            guard contents.isEmpty else { throw NewProjectError.targetNotEmpty(target.path) }
            targetExisted = true
        }

        if !request.nested, let repository = try await enclosingRepository(of: parent) {
            throw NewProjectError.insideRepository(target: target.path, repository: repository)
        }

        // Directories this call makes, so a failure removes exactly those.
        var madeDirectories: [URL] = []
        var ancestor = parent
        var missing: [URL] = []
        while !fm.fileExists(atPath: ancestor.path), ancestor.path != "/" {
            missing.append(ancestor)
            ancestor = ancestor.deletingLastPathComponent()
        }
        do {
            for directory in missing.reversed() {
                try fm.createDirectory(at: directory, withIntermediateDirectories: false)
                madeDirectories.append(directory)
            }
            if !targetExisted {
                try fm.createDirectory(at: target, withIntermediateDirectories: false)
                madeDirectories.append(target)
            }
            try await build(at: target, seeds: seeds, defaults: request.defaults)
        } catch {
            if targetExisted {
                for entry in (try? fm.contentsOfDirectory(atPath: target.path)) ?? [] {
                    try? fm.removeItem(at: target.appendingPathComponent(entry))
                }
            }
            for directory in madeDirectories.reversed() { try? fm.removeItem(at: directory) }
            throw error
        }
        return target.resolvingSymlinksInPath()
    }

    private func build(at target: URL, seeds: [PlannedSeed], defaults: GlobalConfig) async throws {
        try await run(["init", "-q", "-b", "main"], in: target)
        try await run(["commit", "-q", "--allow-empty", "-m", "chore: start the project"], in: target)

        if !seeds.isEmpty {
            let vendor = target.appendingPathComponent("vendor")
            try FileManager.default.createDirectory(at: vendor, withIntermediateDirectories: false)
            for seed in seeds {
                try copy(seed.source, to: vendor.appendingPathComponent(seed.name))
            }
            // -f: the seed's own .gitignore and the user's global excludes must not drop copied files.
            try await run(["add", "-A", "-f", "--", "vendor"], in: target)
            let names = seeds.map(\.name).joined(separator: ", ")
            try await run(["commit", "-q", "--allow-empty", "-m", "chore: seed vendor/ with \(names)"], in: target)
        }

        let project = Project(root: target)
        try FileManager.default.createDirectory(at: project.workbenchDirectory, withIntermediateDirectories: true)
        try await WorktreeManager(repoRoot: target, git: git).excludeWorkbench()
        let text = Config.exampleTOML(claudePath: defaults.claudePath, model: defaults.model)
        // What is written must be a config Workbench itself accepts.
        _ = try Config.parse(text)
        try text.write(to: project.configURL, atomically: true, encoding: .utf8)
    }

    private func run(_ arguments: [String], in directory: URL) async throws {
        let result = try await git.run(arguments, in: directory)
        guard result.succeeded else {
            throw NewProjectError.gitFailed(
                command: arguments.first ?? "", stderr: result.stderr.isEmpty ? result.stdout : result.stderr)
        }
    }

    /// The top level of the repository `directory` is inside, looking from the nearest directory that exists.
    private func enclosingRepository(of directory: URL) async throws -> String? {
        var probe = directory
        while !FileManager.default.fileExists(atPath: probe.path), probe.path != "/" {
            probe = probe.deletingLastPathComponent()
        }
        let result = try await git.run(["rev-parse", "--show-toplevel"], in: probe)
        guard result.succeeded else { return nil }
        let top = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return top.isEmpty ? nil : top
    }

    // MARK: Seeds

    static func plan(seeds: [URL]) throws -> [PlannedSeed] {
        let fm = FileManager.default
        var planned: [PlannedSeed] = []
        var names = Set<String>()
        for url in seeds {
            let source = url.standardizedFileURL
            guard fm.fileExists(atPath: source.path) || isSymlink(source) else {
                throw NewProjectError.seedNotFound(url.path)
            }
            if isSymlink(source) { throw NewProjectError.seedHasSymlink(url.path) }
            let name = source.lastPathComponent
            guard !name.isEmpty, name != ".", name != "..", !skipped(name), !name.contains("\n") else {
                throw NewProjectError.invalidName(name)
            }
            guard names.insert(name).inserted else { throw NewProjectError.seedCollision(name) }

            var files = 0
            var bytes = 0
            if directoryExists(source) {
                var unreadable: String?
                guard
                    let walker = fm.enumerator(
                        at: source, includingPropertiesForKeys: [.isSymbolicLinkKey, .fileSizeKey, .isDirectoryKey],
                        options: [],
                        errorHandler: { failed, _ in
                            unreadable = failed.path
                            return false
                        })
                else { throw NewProjectError.seedNotFound(url.path) }
                for case let entry as URL in walker {
                    if let unreadable { throw NewProjectError.seedUnreadable(unreadable) }
                    if skipped(entry.lastPathComponent) {
                        walker.skipDescendants()
                        continue
                    }
                    if isSymlink(entry) { throw NewProjectError.seedHasSymlink(entry.path) }
                    guard let values = try? entry.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey]),
                        fm.isReadableFile(atPath: entry.path)
                    else { throw NewProjectError.seedUnreadable(entry.path) }
                    if values.isDirectory != true {
                        files += 1
                        bytes += values.fileSize ?? 0
                    }
                    if files > maxSeedFiles || bytes > maxSeedBytes { throw NewProjectError.seedTooLarge(url.path) }
                }
                if let unreadable { throw NewProjectError.seedUnreadable(unreadable) }
            } else {
                files = 1
                guard fm.isReadableFile(atPath: source.path) else { throw NewProjectError.seedUnreadable(url.path) }
                let size = (try? source.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                if size > maxSeedBytes { throw NewProjectError.seedTooLarge(url.path) }
            }
            planned.append(PlannedSeed(source: source, name: name, files: files))
        }
        return planned
    }

    /// Repository metadata and Workbench's own directory never travel in a seed.
    private static func skipped(_ name: String) -> Bool { name == ".git" || name == ".workbench" }

    /// The path with symbolic links resolved as far as it exists, and the rest appended as written.
    private static func resolved(_ url: URL) -> URL {
        var existing = url.standardizedFileURL
        var rest: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
            rest.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        var result = existing.resolvingSymlinksInPath()
        for part in rest { result.appendPathComponent(part) }
        return result
    }

    private static func isSymlink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
    }

    private static func directoryExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func copy(_ source: URL, to destination: URL) throws {
        let fm = FileManager.default
        try beforeCopy?(source)
        guard Self.directoryExists(source) else {
            try fm.copyItem(at: source, to: destination)
            return
        }
        try fm.createDirectory(at: destination, withIntermediateDirectories: false)
        for entry in try fm.contentsOfDirectory(atPath: source.path) where !Self.skipped(entry) {
            try copy(source.appendingPathComponent(entry), to: destination.appendingPathComponent(entry))
        }
    }
}
