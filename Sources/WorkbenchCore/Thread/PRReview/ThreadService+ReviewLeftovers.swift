import Foundation

extension ThreadService {
    /// Ends what killed rounds of any stage left in the thread: one stage's orphaned `codex` must not keep running
    /// beside another stage's reviewer. Call it only while holding the thread's log, so none of them is live.
    func recoverStageLeftovers(id: String, review: ReviewConfig) async {
        let prReview = ReviewConfig.prReviewStage
        let names = review.stages.contains(prReview) ? review.stages : review.stages + [prReview]
        for name in names where ReviewConfig.isStageName(name) {
            await recoverLeftovers(in: project.threadDirectory(id).appendingPathComponent(name))
        }
    }

    /// Ends what an earlier, killed round left: a `codex` still running in the folder, a registered checkout, a saved diff.
    private func recoverLeftovers(in folder: URL) async {
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        OrphanSweeper.sweep(inside: folder)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where name.hasPrefix("round-") && name.hasSuffix(".tree") {
            let tree = folder.appendingPathComponent(name)
            _ = try? await git.run(["worktree", "remove", "--force", tree.path], in: project.root)
            try? FileManager.default.removeItem(at: tree)
        }
        for name in names where name.hasPrefix("round-") && name.hasSuffix(".diff.patch") {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
        _ = try? await git.run(["worktree", "prune"], in: project.root)
    }
}
