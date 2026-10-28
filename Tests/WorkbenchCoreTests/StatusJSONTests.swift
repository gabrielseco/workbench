import Foundation
import Testing

@testable import WorkbenchCore

@Suite(.processGate) struct StatusJSONTests {
    private func status(_ arguments: [String], in fx: RunnerFixture) async throws -> (code: Int32?, stdout: String) {
        let ran = try await workbenchCLI(
            arguments, in: fx.repo,
            environment: ["PATH": "/usr/bin:/bin", "HOME": fx.repo.path, "USER": NSUserName(), "FAKE_CLAUDE": ""])
        #expect(ran.code == 0, "\(ran.stdout) \(ran.stderr)")
        return (ran.code, ran.stdout)
    }

    @Test func spineAndAttentionKeys() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        _ = try await fx.runner(id).run(fx.options())
        let out = try await status(["status", "--json"], in: fx)
        let json = try #require(JSONSerialization.jsonObject(with: Data(out.stdout.utf8)) as? [String: Any])
        #expect(json["v"] as? Int == 1, "keys are added without a new version")
        let spine = try #require(json["spine"] as? [[String: Any]])
        #expect(spine.map { $0["step"] as? String } == ["Goal", "Run", "Review", "Accept", "Ship", "PR review", "Clean"])
        #expect(spine.allSatisfy { Set($0.keys) == ["step", "mark", "sublabel"] && $0["sublabel"] is String })
        #expect(spine.map { $0["mark"] as? String } == ["done", "done", "needs_you", "pending", "pending", "pending", "pending"])
        let attention = try #require(json["attention"] as? [String: Any])
        #expect(Set(attention.keys) == ["state", "reason", "since"])
        #expect(attention["state"] as? String == "needs_you")
        #expect((attention["reason"] as? String)?.hasPrefix("Review · turn 1") == true)
        let events = try EventLogReader.read(at: fx.project.eventsURL(id)).events
        #expect(attention["since"] as? Int == events.last { $0.kind == .turnEnded }?.seq)
    }

    @Test func spineWithNoTurnHasNoReason() async throws {
        let fx = try await RunnerFixture()
        _ = try await fx.approvedThread()
        let out = try await status(["status", "--json"], in: fx)
        let json = try #require(JSONSerialization.jsonObject(with: Data(out.stdout.utf8)) as? [String: Any])
        let attention = try #require(json["attention"] as? [String: Any])
        #expect(attention["state"] as? String == "none" && attention["reason"] is NSNull && attention["since"] is NSNull)
        let spine = try #require(json["spine"] as? [[String: Any]])
        #expect(spine[1]["mark"] as? String == "current" && spine[1]["sublabel"] as? String == "Ready to run")
    }

    @Test func spineTextIsOneLinePerStep() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        _ = try await fx.runner(id).run(fx.options())
        let lines = try await status(["status"], in: fx).stdout.split(separator: "\n").map(String.init)
        let first = try #require(lines.firstIndex { $0.hasPrefix("spine:") })
        let steps = ["Goal", "Run", "Review", "Accept", "Ship", "PR review", "Clean"]
        #expect(lines.count >= first + 8, "\(lines)")
        for (offset, step) in steps.enumerated() {
            #expect(lines[first + offset].dropFirst(11).hasPrefix(step), "\(lines[first + offset])")
        }
        #expect(lines[first + 2].contains("needs_you"))
        #expect(lines[first + 7].hasPrefix("attention: needs you: Review · turn 1"), "\(lines[first + 7])")
    }
}
