import Foundation
import Testing

@testable import WorkbenchCore

/// A `pr-shots` that names files under its own directory and records what it was asked.
private struct FakeShots {
    let dir: URL
    let runner: GitRunner

    init(in fx: RunnerFixture, failing: Bool = false, badPath: Bool = false) throws {
        dir = fx.repo.deletingLastPathComponent().appendingPathComponent("shots-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("out"), withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("pr-shots")
        try """
            #!/bin/sh
            echo "$(pwd -P): $@" >> "\(dir.path)/calls"
            case "$1" in
            path) \(badPath ? "echo relative.png" : "echo \"\(dir.path)/out/branch-$2-sha.png\"") ;;
            pr) \(failing ? "echo 'no store configured' >&2; exit 1" : "exit 0") ;;
            esac
            """.write(to: script, atomically: true, encoding: .utf8)
        chmod(script.path, 0o755)
        runner = GitRunner(executable: script, environment: ["PATH": "/usr/bin:/bin"], timeout: 10)
    }

    var calls: [String] {
        ((try? String(contentsOf: dir.appendingPathComponent("calls"), encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    func shot(_ name: String) -> String? {
        try? String(contentsOf: dir.appendingPathComponent("out/branch-\(name)-sha.png"), encoding: .utf8)
    }
}

private struct Shipped {
    var fx: RunnerFixture
    var id: String
    var plan: ShipPlan
}

private func shippedThread(_ files: [String: String] = ["home.png": "pixels"]) async throws -> Shipped {
    let writes = files.map { "printf '\($0.value)' > \"$WORKBENCH_PROOF_DIR/\($0.key)\"" }.joined(separator: "\n")
    let script = try CheckScript()
    let verify = try script.write(writes, name: "verify.sh")
    let fx = try await RunnerFixture(extraConfig: "verify_command = \"\(verify)\"")
    let (id, worktree) = try await acceptedThread(fx)
    let plan = ShipPlan(
        id: id, worktree: worktree, branch: "workbench/\(id)", remoteBranch: "workbench/\(id)", base: "main",
        head: "abc", origin: "o", remote: .absent)
    return Shipped(fx: fx, id: id, plan: plan)
}

@Suite struct ShipScreenshotsTests {
    @Test func theVerifyStepsPNGsAreCopiedToPrShotsNamesAndPublished() async throws {
        let shipped = try await shippedThread(["home.png": "pixels", "notes.txt": "x", "verdict.json": "{}"])
        let (fx, id, plan) = (shipped.fx, shipped.id, shipped.plan)
        let tool = try FakeShots(in: fx)
        let result = await fx.service.shipScreenshots(id: id, plan: plan, number: 12, tool: tool.runner)

        #expect(result == .attached(count: 1))
        #expect(tool.shot("home") == "pixels", "copied to where `pr-shots path home` said")
        #expect(tool.calls.map { $0.split(separator: ":", maxSplits: 1).last.map(String.init) } == [" path home", " pr 12"])
        let here = OrphanSweeper.realPath(plan.worktree)
        #expect(tool.calls.allSatisfy { $0.hasPrefix(here + ":") }, "run in the thread's worktree: \(tool.calls)")
        let event = try #require(try fx.events(id).last { $0.kind == .proofPublished })
        #expect(event.data["number"]?.intValue == 12)
        #expect(event.data["files"] == ["home.png"])
    }

    @Test func noScreenshotsMeansNothingIsRunOrSaid() async throws {
        let shipped = try await shippedThread(["notes.txt": "x"])
        let (fx, id, plan) = (shipped.fx, shipped.id, shipped.plan)
        let tool = try FakeShots(in: fx)
        #expect(await fx.service.shipScreenshots(id: id, plan: plan, number: 1, tool: tool.runner) == .none)
        #expect(tool.calls.isEmpty)
    }

    @Test func aThreadWithNoVerifyStepIsLeftAlone() async throws {
        let fx = try await RunnerFixture()
        let (id, worktree) = try await acceptedThread(fx)
        let plan = ShipPlan(
            id: id, worktree: worktree, branch: "b", remoteBranch: "b", base: "main", head: "abc", origin: "o",
            remote: .absent)
        let tool = try FakeShots(in: fx)
        #expect(await fx.service.shipScreenshots(id: id, plan: plan, number: 1, tool: tool.runner) == .none)
    }

    @Test func aMissingToolIsANoteNotAnError() async throws {
        let shipped = try await shippedThread()
        let (fx, id, plan) = (shipped.fx, shipped.id, shipped.plan)
        let result = await fx.service.shipScreenshots(id: id, plan: plan, number: 1, tool: nil)
        guard case .skipped(let why) = result else {
            Issue.record("expected skipped, got \(result)")
            return
        }
        #expect(why.contains("pr-shots") && why.contains("1 screenshot not attached"))
        #expect(try !fx.events(id).contains { $0.kind == .proofPublished })
    }

    @Test func aFailedUploadIsANoteAndRecordsNothing() async throws {
        let shipped = try await shippedThread()
        let (fx, id, plan) = (shipped.fx, shipped.id, shipped.plan)
        let tool = try FakeShots(in: fx, failing: true)
        let result = await fx.service.shipScreenshots(id: id, plan: plan, number: 5, tool: tool.runner)
        guard case .skipped(let why) = result else {
            Issue.record("expected skipped, got \(result)")
            return
        }
        #expect(why.contains("no store configured"))
        #expect(try !fx.events(id).contains { $0.kind == .proofPublished })
    }

    @Test func aFileNameThatIsNotAbsoluteIsNotCopiedTo() async throws {
        let shipped = try await shippedThread()
        let (fx, id, plan) = (shipped.fx, shipped.id, shipped.plan)
        let tool = try FakeShots(in: fx, badPath: true)
        let result = await fx.service.shipScreenshots(id: id, plan: plan, number: 5, tool: tool.runner)
        guard case .skipped(let why) = result else {
            Issue.record("expected skipped, got \(result)")
            return
        }
        #expect(why.contains("no usable file name"))
        #expect(!tool.calls.contains { $0.hasSuffix(" pr 5") })
    }

    @Test func aScreenshotRemovedSinceTheVerifyIsNotPublished() async throws {
        let shipped = try await shippedThread()
        let (fx, id, plan) = (shipped.fx, shipped.id, shipped.plan)
        let events = try fx.events(id)
        let shot = try #require(events.last { $0.kind == .proofAdded }?.data["path"]?.stringValue)
        try FileManager.default.removeItem(at: fx.project.threadDirectory(id).appendingPathComponent(shot))
        let tool = try FakeShots(in: fx)
        #expect(await fx.service.shipScreenshots(id: id, plan: plan, number: 1, tool: tool.runner) == .none)
        #expect(tool.calls.isEmpty)
    }
}
