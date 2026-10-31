import Foundation
import Testing

@testable import WorkbenchCore

struct TaskPendingTests {
    private let units = ["ROU", "TUR", "PAN", "PRI"].map { TaskUnit(id: $0, title: $0) }

    private func history(done: [String: String] = [:]) async throws -> TaskHistory {
        let fx = try TaskFixture()
        let writer = try await fx.log.openWriter()
        for (unit, thread) in done {
            try await writer.append(.taskRunStarted, data: ["trigger": "tick"])
            try await writer.append(
                .taskRunEnded, data: ["outcome": "pr-opened", "units": [.string(unit)], "thread": .string(thread)])
        }
        await writer.close()
        return try fx.log.history()
    }

    @Test func takesTheNextBatchInTheScriptsOrder() async throws {
        let picked = PendingUnits.select(units: units, history: try await history(), pullRequests: [:], batch: 2)
        #expect(picked.map(\.id) == ["ROU", "TUR"])
    }

    @Test func aUnitWithARecordedPullRequestIsNotPickedAgain() async throws {
        let past = try await history(done: ["ROU": "g-1"])
        // Its state could not be found out: left alone rather than done twice.
        #expect(PendingUnits.select(units: units, history: past, pullRequests: [:], batch: 3).map(\.id) == ["TUR", "PAN", "PRI"])
        for state in [UnitPullRequest.open, .merged] {
            let picked = PendingUnits.select(units: units, history: past, pullRequests: ["ROU": state], batch: 3)
            #expect(picked.map(\.id) == ["TUR", "PAN", "PRI"])
        }
    }

    @Test func aClosedUnmergedPullRequestMakesTheUnitPendingAgain() async throws {
        let past = try await history(done: ["ROU": "g-1"])
        let picked = PendingUnits.select(units: units, history: past, pullRequests: ["ROU": .closed], batch: 1)
        #expect(picked.map(\.id) == ["ROU"])
    }

    @Test func aPullRequestOpenedByHandAlsoCounts() async throws {
        let picked = PendingUnits.select(units: units, history: try await history(), pullRequests: ["ROU": .open], batch: 1)
        #expect(picked.map(\.id) == ["TUR"])
    }

    @Test func nothingLeftIsAnEmptyList() async throws {
        let all = Dictionary(uniqueKeysWithValues: units.map { ($0.id, UnitPullRequest.merged) })
        #expect(PendingUnits.select(units: units, history: try await history(), pullRequests: all, batch: 2).isEmpty)
    }

    @Test func aUnitGitHubSaysHasNoPullRequestIsOfferedAgainUnlessARunRecordedOne() async throws {
        let fx = try TaskFixture()
        let writer = try await fx.log.openWriter()
        // ROU: a run that died with a thread and no end. TUR: a run that recorded its pull request.
        try await writer.append(.taskRunStarted, data: ["trigger": "tick"])
        try await writer.append(.taskRunThread, data: ["thread": "g-1", "units": ["ROU"]])
        await writer.close()
        let again = try await fx.log.openWriter()
        try await again.append(.taskRunStarted, data: ["trigger": "tick"])
        try await again.append(.taskRunEnded, data: ["outcome": "pr-opened", "units": ["TUR"], "thread": "g-2"])
        await again.close()
        let history = try fx.log.history()
        #expect(history.unitsWithThreads == ["ROU": "g-1", "TUR": "g-2"])
        let picked = PendingUnits.select(
            units: units, history: history, pullRequests: ["ROU": .absent, "TUR": .absent], batch: 4)
        #expect(picked.map(\.id) == ["ROU", "PAN", "PRI"])
        // GitHub unreachable: neither is touched.
        #expect(PendingUnits.select(units: units, history: history, pullRequests: [:], batch: 4).map(\.id) == ["PAN", "PRI"])
        // The dead run's pull request is open: it stays out too.
        let open = PendingUnits.select(units: units, history: history, pullRequests: ["ROU": .open], batch: 4)
        #expect(open.map(\.id) == ["PAN", "PRI"])
    }

    @Test func aReportRunDoesTheWorkOfNoUnit() async throws {
        let fx = try TaskFixture()
        let writer = try await fx.log.openWriter()
        try await writer.append(.taskRunStarted, data: ["trigger": "tick"])
        try await writer.append(.taskRunEnded, data: ["outcome": "reported", "units": ["ROU"], "thread": "g-1"])
        await writer.close()
        let picked = PendingUnits.select(units: units, history: try fx.log.history(), pullRequests: [:], batch: 1)
        #expect(picked.map(\.id) == ["ROU"])
    }
}

@Suite(.processGate) struct TaskPendingScriptTests {
    private func script(_ fx: TaskFixture, _ body: String) throws {
        try fx.write("pending.sh", "#!/bin/sh\n\(body)\n")
        let path = fx.project.root.appendingPathComponent("pending.sh").path
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }

    private func units(_ fx: TaskFixture, timeout: TimeInterval = 20) async throws -> [TaskUnit] {
        try await PendingUnits.run(script: "pending.sh", project: fx.project, timeout: timeout)
    }

    @Test func readsAListOfUnitsFromTheScript() async throws {
        let fx = try TaskFixture()
        try script(fx, #"echo '[{"id":"ROU","title":"Romania v1 -> v6"},{"id":"TUR"}]'"#)
        #expect(try await units(fx) == [TaskUnit(id: "ROU", title: "Romania v1 -> v6"), TaskUnit(id: "TUR", title: "TUR")])
    }

    @Test func theScriptReadsAnyInputFileTheTaskPointsAt() async throws {
        let fx = try TaskFixture()
        try fx.write("countries.txt", "ROU\nTUR\n")
        try script(fx, #"printf '['; sed 's/.*/{"id":"&"}/' countries.txt | paste -sd, -; printf ']'"#)
        #expect(try await units(fx).map(\.id) == ["ROU", "TUR"])
    }

    @Test func anIdThatCouldReachGitOrAPathIsRefused() async throws {
        for bad in ["../x", "-rf", "a b", "x;rm", "", "a/b"] {
            let fx = try TaskFixture()
            try script(fx, "echo '[{\"id\":\"\(bad)\"}]'")
            await #expect(throws: PendingScriptError.self) { _ = try await units(fx) }
        }
    }

    @Test func aDuplicateIdAndNonListOutputAreRefused() async throws {
        let fx = try TaskFixture()
        try script(fx, #"echo '[{"id":"A"},{"id":"A"}]'"#)
        await #expect(throws: PendingScriptError.self) { _ = try await units(fx) }
        try script(fx, "echo hello")
        await #expect(throws: PendingScriptError.malformed("not JSON")) { _ = try await units(fx) }
        try script(fx, #"echo '{"id":"A"}'"#)
        await #expect(throws: PendingScriptError.self) { _ = try await units(fx) }
    }

    @Test func aFailingScriptEndsTheRunWithItsReason() async throws {
        let fx = try TaskFixture()
        try script(fx, "echo boom >&2; exit 3")
        await #expect(throws: PendingScriptError.failed(exit: 3, stderr: "boom\n")) { _ = try await units(fx) }
    }

    @Test func aScriptThatHangsIsStopped() async throws {
        let fx = try TaskFixture()
        try script(fx, "sleep 30")
        await #expect(throws: PendingScriptError.timedOut(seconds: 1)) { _ = try await units(fx, timeout: 1) }
    }

    @Test func aScriptThatIsNotExecutableOrOutsideTheProjectIsRefused() async throws {
        let fx = try TaskFixture()
        try fx.write("plain.sh", "echo '[]'")
        await #expect(throws: PendingScriptError.notExecutable("plain.sh")) {
            _ = try await PendingUnits.run(script: "plain.sh", project: fx.project)
        }
        await #expect(throws: TaskFileError.self) { _ = try await PendingUnits.run(script: "../x.sh", project: fx.project) }
    }

    @Test func tooMuchOutputIsRefused() async throws {
        let fx = try TaskFixture()
        try script(fx, "yes x | head -c 5000000")
        await #expect(throws: PendingScriptError.outputTooLarge) { _ = try await units(fx) }
    }

    @Test func theScriptSeesNothingButAPlainEnvironment() async throws {
        let fx = try TaskFixture()
        try script(fx, #"echo "[{\"id\":\"${SECRET_TOKEN:-none}\"}]""#)
        let units = try await PendingUnits.run(
            script: "pending.sh", project: fx.project, environment: ["PATH": "/usr/bin:/bin", "SECRET_TOKEN": "leak"])
        #expect(units.map(\.id) == ["none"])
    }
}
