import Foundation

extension ThreadService {
    /// The most a goal file given to `goal new --from` may be, so a wrong path cannot read a huge file.
    static let copySourceLimit = 256 << 10
    /// How many suffixes are tried before giving up on a name.
    static let suffixAttempts = 8

    /// Makes the thread directory for `plain`, or for `plain-<suffix>` when a thread or a `workbench/<id>`
    /// branch already has that id, so one goal can be started again. The branch check is here because
    /// `WorktreeManager.create` would otherwise refuse the run, after the goal was written.
    func createThreadDirectory(for plain: String) async throws -> String {
        var id = plain
        for _ in 0..<Self.suffixAttempts {
            if try await !idTaken(id) {
                do {
                    try ThreadStore(project: project).create(id: id)
                    return id
                } catch ThreadStoreError.threadExists {}  // lost a race for it; take another suffix
            }
            id = "\(plain)-\(idSuffix())"
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

    /// The request, criteria and out of scope of an existing goal file, for `goal new --from`. Nothing else
    /// comes along: not the status, the hash, the id, the base or the budget.
    public static func goalBody(copying url: URL) throws -> GoalBody {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes?[.size] as? Int else { throw ThreadServiceError.copySourceMissing(url.path) }
        if size > copySourceLimit { throw ThreadServiceError.copySourceTooLarge(url.path) }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw ThreadServiceError.copySourceMissing(url.path)
        }
        let file: GoalFile
        do { file = try GoalFile.parse(text) } catch let error as GoalParseError {
            throw ThreadServiceError.goalInvalid(error.description)
        }
        return GoalBody(
            request: file.goal.request,
            criteria: file.goal.criteria.map { GoalBody.Criterion(id: $0.id, text: $0.text, proof: $0.proof) },
            outOfScope: file.goal.outOfScope)
    }
}
