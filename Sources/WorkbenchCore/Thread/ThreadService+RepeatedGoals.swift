import Foundation

extension ThreadService {
    /// The most a goal file given to `goal new --from` may be, so a wrong path cannot read a huge file.
    static let copySourceLimit = 256 << 10
    /// How many suffixes are tried before giving up on a name.
    static let suffixAttempts = 8
    /// The longest id stem that still fits under `SafeNames`' 100 characters with a 5 character suffix.
    static let maxStem = 95

    /// Makes the thread directory for `plain`, or for `plain-<suffix>` when a thread or a `workbench/<id>`
    /// branch already has that id, so one goal can be started again. The branch check is here because
    /// `WorktreeManager.create` would otherwise refuse the run, after the goal was written.
    func createThreadDirectory(for plain: String) async throws -> String {
        var id = plain
        // The plain id is tried first, then `suffixAttempts` suffixed ones.
        for _ in 0...Self.suffixAttempts {
            if try await !idTaken(id) {
                do {
                    try ThreadStore(project: project).create(id: id)
                    return id
                } catch ThreadStoreError.threadExists {}  // lost a race for it; take another suffix
            }
            // Room is kept for "-xxxx" so a long name that was valid still gets a valid id.
            id = "\(plain.prefix(Self.maxStem))-\(idSuffix())"
        }
        throw ThreadServiceError.noFreeID(plain)
    }

    private func idTaken(_ id: String) async throws -> Bool {
        guard SafeNames.isThreadID(id) else { throw ThreadStoreError.invalidName(id) }
        if FileManager.default.fileExists(atPath: project.threadDirectory(id).path) { return true }
        let probe = try await git.run(
            ["show-ref", "--verify", "--quiet", "refs/heads/\(WorktreeManager.branch(for: id))"],
            in: project.root)
        return probe.succeeded
    }

    /// The request, criteria and out of scope of an existing goal file, for `goal new --from`, with its `title`,
    /// `budget_usd`, `turn_timeout_min` and `model`. The rest of its front matter (the id, base, status, approval)
    /// belongs to that file's thread and is named in `ignoredKeys`.
    public static func goalCopy(copying url: URL) throws -> GoalCopy {
        let text = try readBounded(url)
        do { return try GoalFile.copy(text) } catch let error as GoalParseError {
            throw ThreadServiceError.goalInvalid(error.description)
        } catch let error as GoalCopyValueError {
            throw ThreadServiceError.copyValueInvalid(error.message)
        }
    }

    /// Reads a regular file of at most `copySourceLimit` bytes. The descriptor is opened without blocking
    /// and checked after opening, and the read stops one byte past the limit, so a file that grows after
    /// the check or a FIFO cannot make it read without bound or wait for ever.
    private static func readBounded(_ url: URL) throws -> String {
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw ThreadServiceError.copySourceMissing(url.path) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw ThreadServiceError.copySourceMissing(url.path)
        }
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 16 << 10)
        while data.count <= copySourceLimit {
            let n = read(fd, &chunk, min(chunk.count, copySourceLimit + 1 - data.count))
            if n < 0 { throw ThreadServiceError.copySourceMissing(url.path) }
            if n == 0 { break }
            data.append(contentsOf: chunk[0..<n])
        }
        if data.count > copySourceLimit { throw ThreadServiceError.copySourceTooLarge(url.path) }
        guard let text = String(data: data, encoding: .utf8) else {
            throw ThreadServiceError.copySourceMissing(url.path)
        }
        return text
    }
}
