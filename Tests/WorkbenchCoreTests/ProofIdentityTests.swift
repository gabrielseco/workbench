import Foundation
import Testing

@testable import WorkbenchCore

@Suite(.processGate) struct ProofIdentityTests {
    private func head(_ ref: String, _ fx: RunnerFixture, in dir: URL) async throws -> String {
        try await fx.git.run(["rev-parse", ref], in: dir).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A thread's own worktree: a clean checkout, unlike the repository root, which holds Workbench's files.
    private func worktree(_ fx: RunnerFixture) async throws -> URL {
        let id = try await fx.approvedThread()
        _ = try await fx.runner(id).run(fx.options())
        return fx.project.worktreesDirectory.appendingPathComponent(id)
    }

    @Test func aCleanWorktreeIsItsHeadCommitAndTree() async throws {
        let fx = try await RunnerFixture()
        let wt = try await worktree(fx)
        let identity = try #require(await ProofIdentity.of(worktree: wt, git: fx.git, attributesFrom: nil))
        #expect(identity.commit == (try await head("HEAD", fx, in: wt)))
        #expect(identity.tree == (try await head("HEAD^{tree}", fx, in: wt)))
    }

    @Test func aChangeToATrackedFileChangesTheTreeButNotTheCommit() async throws {
        let fx = try await RunnerFixture()
        let wt = try await worktree(fx)
        let clean = try #require(await ProofIdentity.of(worktree: wt, git: fx.git, attributesFrom: nil))
        try "edited\n".write(to: wt.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let dirty = try #require(await ProofIdentity.of(worktree: wt, git: fx.git, attributesFrom: nil))
        #expect(dirty.commit == clean.commit)
        #expect(dirty.tree != clean.tree)
    }

    @Test func anUntrackedFileCountsAndTheWorktreesOwnIndexIsLeftAlone() async throws {
        let fx = try await RunnerFixture()
        let wt = try await worktree(fx)
        let clean = try #require(await ProofIdentity.of(worktree: wt, git: fx.git, attributesFrom: nil))
        try "new\n".write(to: wt.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        let before = try await fx.git.run(["status", "--porcelain"], in: wt).stdout
        let withNew = try #require(await ProofIdentity.of(worktree: wt, git: fx.git, attributesFrom: nil))
        let after = try await fx.git.run(["status", "--porcelain"], in: wt).stdout
        #expect(withNew.tree != clean.tree)
        #expect(before == after)
        #expect(after.contains("?? new.txt"))
    }

    @Test func committingTheWorkKeepsTheTreeSoTheProofStaysCurrent() async throws {
        let fx = try await RunnerFixture()
        let wt = try await worktree(fx)
        try "edited\n".write(to: wt.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let uncommitted = try #require(await ProofIdentity.of(worktree: wt, git: fx.git, attributesFrom: nil))
        _ = try await fx.git.run(["commit", "-qam", "work"], in: wt)
        let committed = try #require(await ProofIdentity.of(worktree: wt, git: fx.git, attributesFrom: nil))
        #expect(committed.commit != uncommitted.commit)
        #expect(committed.tree == uncommitted.tree)
        #expect(ProofFreshness.of(recordedTree: uncommitted.tree, current: committed) == .current)
    }

    @Test func theCommittedIdentityIgnoresWhatIsNotCommitted() async throws {
        let fx = try await RunnerFixture()
        let wt = try await worktree(fx)
        let before = try #require(await ProofIdentity.committed(worktree: wt, git: fx.git))
        try "new\n".write(to: wt.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        try "edited\n".write(to: wt.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        #expect(await ProofIdentity.committed(worktree: wt, git: fx.git) == before)
        #expect(before.tree == (try await head("HEAD^{tree}", fx, in: wt)))
    }

    @Test func aFilterTheRunNamedInTheWorktreeIsNotExecutedToComputeTheIdentity() async throws {
        let fx = try await RunnerFixture()
        let wt = try await worktree(fx)
        let marker = fx.repo.deletingLastPathComponent().appendingPathComponent("filter-ran-\(UUID().uuidString)")
        let script = fx.repo.deletingLastPathComponent().appendingPathComponent("clean-\(UUID().uuidString).sh")
        try "#!/bin/sh\necho ran >> \"\(marker.path)\"\ncat\n".write(to: script, atomically: true, encoding: .utf8)
        chmod(script.path, 0o755)
        _ = try await fx.git.run(["config", "filter.evil.clean", script.path], in: wt)
        // What the run could write: an attribute naming the filter, and a change for it to apply to.
        try "a.txt filter=evil\n".write(to: wt.appendingPathComponent(".gitattributes"), atomically: true, encoding: .utf8)
        try "edited\n".write(to: wt.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        // The control: plain `git add` does run it, so the assertion below is about the fix and not about git.
        let index = fx.repo.deletingLastPathComponent().appendingPathComponent("idx-\(UUID().uuidString)")
        var env = fx.git.environment
        env["GIT_INDEX_FILE"] = index.path
        let plain = GitRunner(executable: fx.git.executable, environment: env, timeout: fx.git.timeout)
        _ = try await plain.run(["read-tree", "HEAD"], in: wt)
        _ = try await plain.run(["add", "-A"], in: wt)
        #expect(FileManager.default.fileExists(atPath: marker.path))
        try FileManager.default.removeItem(at: marker)

        let identity = await ProofIdentity.of(worktree: wt, git: fx.git, attributesFrom: nil)
        #expect(identity != nil)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func noCommitMeansNoIdentity() async throws {
        let fx = try await RunnerFixture()
        let empty = fx.repo.deletingLastPathComponent().appendingPathComponent("unborn-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        _ = try await fx.git.run(["init", "-q"], in: empty)
        #expect(await ProofIdentity.of(worktree: empty, git: fx.git, attributesFrom: nil) == nil)
        #expect(await ProofIdentity.committed(worktree: empty, git: fx.git) == nil)
    }
}

@Suite(.processGate) struct ProofFreshnessTests {
    private let now = ProofIdentity(commit: "c2", tree: "t2")

    @Test func theSameTreeIsCurrentAndAnotherIsStale() {
        #expect(ProofFreshness.of(recordedTree: "t2", current: now) == .current)
        #expect(ProofFreshness.of(recordedTree: "t1", current: now) == .stale)
    }

    @Test func aMissingOrEmptyRecordOrAnUnreadableWorktreeIsUnknownNotStale() {
        #expect(ProofFreshness.of(recordedTree: nil, current: now) == .unknown)
        #expect(ProofFreshness.of(recordedTree: "", current: now) == .unknown)
        #expect(ProofFreshness.of(recordedTree: "t1", current: nil) == .unknown)
    }
}

@Suite(.processGate) struct ProofIdentityRecordTests {
    private func proofAdded(_ extra: [String: JSONValue]) -> Event {
        var data: [String: JSONValue] = [
            "name": "home.png", "path": "proof/turn-1/home.png", "sha256": "ab", "bytes": 4, "source": "verifier",
        ]
        for (key, value) in extra { data[key] = value }
        return Event(seq: 3, ts: "t", turn: 1, kind: .proofAdded, data: .object(data))
    }

    private func file(_ added: Event) -> ProofFile? {
        let started = Event(seq: 2, ts: "t", turn: 1, kind: .verifierStarted, data: [:])
        let ended = Event(seq: 4, ts: "t", turn: 1, kind: .verifierEnded, data: ["ok": true])
        return ThreadState.derive(from: [started, added, ended], id: "g-x").review.verifier?.proof.first
    }

    @Test func aFileKeepsTheCommitAndTreeItRecorded() {
        let proof = file(proofAdded(["commit": "c1", "tree": "t1"]))
        #expect(proof?.commit == "c1")
        #expect(proof?.tree == "t1")
    }

    @Test func anOlderLogWithNeitherReadsAsNoIdentity() {
        let proof = file(proofAdded([:]))
        #expect(proof != nil && proof?.commit == nil && proof?.tree == nil)
        #expect(ProofFreshness.of(recordedTree: proof?.tree, current: ProofIdentity(commit: "c", tree: "t")) == .unknown)
    }

    @Test func aNullTreeFromAWorktreeGitCouldNotReadIsNotAString() {
        let proof = file(proofAdded(["commit": .null, "tree": .null]))
        #expect(proof != nil && proof?.tree == nil)
    }
}
