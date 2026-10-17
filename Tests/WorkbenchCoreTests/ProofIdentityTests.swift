import Foundation
import Testing

@testable import WorkbenchCore

@Suite struct ProofIdentityTests {
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
        let identity = try #require(await ProofIdentity.of(worktree: wt, git: fx.git))
        #expect(identity.commit == (try await head("HEAD", fx, in: wt)))
        #expect(identity.tree == (try await head("HEAD^{tree}", fx, in: wt)))
    }

    @Test func aChangeToATrackedFileChangesTheTreeButNotTheCommit() async throws {
        let fx = try await RunnerFixture()
        let wt = try await worktree(fx)
        let clean = try #require(await ProofIdentity.of(worktree: wt, git: fx.git))
        try "edited\n".write(to: wt.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let dirty = try #require(await ProofIdentity.of(worktree: wt, git: fx.git))
        #expect(dirty.commit == clean.commit)
        #expect(dirty.tree != clean.tree)
    }

    @Test func anUntrackedFileCountsAndTheWorktreesOwnIndexIsLeftAlone() async throws {
        let fx = try await RunnerFixture()
        let wt = try await worktree(fx)
        let clean = try #require(await ProofIdentity.of(worktree: wt, git: fx.git))
        try "new\n".write(to: wt.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        let before = try await fx.git.run(["status", "--porcelain"], in: wt).stdout
        let withNew = try #require(await ProofIdentity.of(worktree: wt, git: fx.git))
        let after = try await fx.git.run(["status", "--porcelain"], in: wt).stdout
        #expect(withNew.tree != clean.tree)
        #expect(before == after)
        #expect(after.contains("?? new.txt"))
    }

    @Test func committingTheWorkKeepsTheTreeSoTheProofStaysCurrent() async throws {
        let fx = try await RunnerFixture()
        let wt = try await worktree(fx)
        try "edited\n".write(to: wt.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let uncommitted = try #require(await ProofIdentity.of(worktree: wt, git: fx.git))
        _ = try await fx.git.run(["commit", "-qam", "work"], in: wt)
        let committed = try #require(await ProofIdentity.of(worktree: wt, git: fx.git))
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

    @Test func noCommitMeansNoIdentity() async throws {
        let fx = try await RunnerFixture()
        let empty = fx.repo.deletingLastPathComponent().appendingPathComponent("unborn-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        _ = try await fx.git.run(["init", "-q"], in: empty)
        #expect(await ProofIdentity.of(worktree: empty, git: fx.git) == nil)
        #expect(await ProofIdentity.committed(worktree: empty, git: fx.git) == nil)
    }
}

@Suite struct ProofFreshnessTests {
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

@Suite struct ProofFreshnessTextTests {
    @Test func reviewSaysWhichCommitAProofWasTakenAtAndWhetherItStillHolds() {
        #expect(ReviewReport.freshnessText(.current, commit: "972aa0f1234").contains("972aa0f: still describes the work"))
        #expect(ReviewReport.freshnessText(.stale, commit: "972aa0f1234").contains("STALE"))
        #expect(ReviewReport.freshnessText(.stale, commit: "972aa0f1234").contains("run verify again"))
        #expect(ReviewReport.freshnessText(.unknown, commit: nil).contains("cannot tell"))
    }
}

@Suite struct ProofIdentityRecordTests {
    private func proofAdded(_ extra: [String: JSONValue]) -> Event {
        var data: [String: JSONValue] = ["name": "home.png", "path": "proof/turn-1/home.png", "sha256": "ab", "bytes": 4]
        for (key, value) in extra { data[key] = value }
        return Event(seq: 3, ts: "t", turn: 1, kind: .proofAdded, data: .object(data))
    }

    private func state(_ added: Event) -> ThreadState {
        let started = Event(seq: 2, ts: "t", turn: 1, kind: .verifyStarted, data: ["command": "v.sh"])
        let ended = Event(seq: 4, ts: "t", turn: 1, kind: .verifyEnded, data: ["result": "passed"])
        return ThreadState.derive(from: [started, added, ended], id: "g-x")
    }

    @Test func theStepKeepsTheCommitAndTreeItsProofFilesRecorded() {
        let verify = state(proofAdded(["commit": "c1", "tree": "t1"])).review.verify
        #expect(verify?.commit == "c1")
        #expect(verify?.tree == "t1")
    }

    @Test func anOlderLogWithNeitherReadsAsNoIdentity() {
        let verify = state(proofAdded([:])).review.verify
        #expect(verify?.commit == nil)
        #expect(verify?.tree == nil)
        #expect(ProofFreshness.of(recordedTree: verify?.tree, current: ProofIdentity(commit: "c", tree: "t")) == .unknown)
    }

    @Test func aNullTreeFromAWorktreeGitCouldNotReadIsNotAString() {
        let verify = state(proofAdded(["commit": .null, "tree": .null])).review.verify
        #expect(verify?.tree == nil)
    }
}
