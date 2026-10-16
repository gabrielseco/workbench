import Foundation
import Testing

@testable import WorkbenchCore

/// Codex failing, hanging or being stopped.
@Suite struct PRReviewCodexTests {
    // MARK: Codex failing

    @Test func atCapacityRetriesThenSucceedsOrGivesUpSaying() async throws {
        let r = try await reviewedPR()
        try r.codex.put("capacity_until", "1")
        let result = try await r.round()
        #expect(result.verdict == .clean && r.codex.runs == 2)

        let g = try await reviewedPR()
        try g.codex.put("capacity_until", "9")
        let gaveUp = try await g.round()
        #expect(gaveUp.verdict == nil && gaveUp.failure?.contains("at capacity 3 times") == true)
        #expect(g.codex.runs == 3, "three tries, no more")
        #expect(g.finished.count == 1)
        try await g.expectNoLeftovers()
    }

    @Test func aMissingCodexIsAFailureWithTheReason() async throws {
        let r = try await reviewedPR()
        let result = try await r.round(codexPath: "/nonexistent/codex")
        #expect(result.verdict == nil && result.failure?.contains("was not found") == true)
        let byName = try await r.round(environment: ["PATH": "/nonexistent"], codexPath: "codex")
        #expect(byName.verdict == nil && byName.failure?.contains("was not found") == true)
        try await r.expectNoLeftovers()
    }

    @Test func aCrashIsAFailureAndTheStderrTailSaysWhy() async throws {
        let r = try await reviewedPR()
        try r.codex.put("crash", "")
        let result = try await r.round()
        #expect(result.verdict == nil)
        #expect(result.failure?.contains("status 70") == true && result.failure?.contains("boom") == true)
        try await r.expectNoLeftovers()
    }

    @Test func aHangingCodexIsEndedAtTheTimeoutAndNothingStaysRunning() async throws {
        let r = try await reviewedPR()
        try r.codex.put("hang", "")
        let result = try await r.round(timeout: 8)
        #expect(result.verdict == nil && result.failure?.contains("did not finish within 8s") == true)
        let pid = try #require(Int32(r.codex.read("pid")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""))
        #expect(await pollUntil { kill(pid, 0) != 0 }, "codex is gone")
        try await r.expectNoLeftovers()
        #expect(r.fx.service.runnerPID(id: r.id) == nil)
    }

    @Test func anAnswerPastTheLimitIsNeverReadAsAVerdictFromItsPrefix() async throws {
        let r = try await reviewedPR()
        try r.codex.put("big", "")
        let result = try await r.round()
        #expect(result.verdict == nil && result.failure?.contains("larger than 256 KiB") == true)
        #expect(r.finished.first?.data["ok"] == false)
    }

    @Test func aFloodOfOutputIsBoundedAndTheRoundStillEnds() async throws {
        let r = try await reviewedPR()
        try r.codex.put("flood", "")
        let result = try await r.round()
        #expect(result.verdict == .clean, "the answer file, not the stream, carries the verdict")
        let transcript = r.folder.appendingPathComponent("round-1.transcript.txt")
        let size = try #require(try FileManager.default.attributesOfItem(atPath: transcript.path)[.size] as? Int)
        #expect(size < PRReview.transcriptLimit + (64 << 10), "kept \(size) bytes of a 6 MB flood")
    }

    @Test func stoppingEndsTheReviewAndRecordsWhy() async throws {
        let r = try await reviewedPR()
        try r.codex.put("hang", "")
        try r.codex.put("ignore_term", "")
        let dir = r.codex.dir
        let result = try await r.round(attach: { run in
            Task {
                // Not before codex is up and ignoring SIGTERM.
                _ = await pollUntil { FileManager.default.fileExists(atPath: dir.appendingPathComponent("calls").path) }
                try await Task.sleep(nanoseconds: 300_000_000)
                run.stop()
            }
        })
        #expect(result.verdict == nil && result.failure == "the review was stopped")
        #expect(r.finished.first?.data["ok"] == false)
        let pid = try #require(Int32(r.codex.read("pid")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""))
        #expect(await pollUntil { kill(pid, 0) != 0 }, "even a codex that ignores SIGTERM is gone")
        try await r.expectNoLeftovers()
    }
}
