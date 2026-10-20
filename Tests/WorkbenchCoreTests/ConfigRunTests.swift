import Foundation
import Testing

@testable import WorkbenchCore

@Suite struct ConfigRunTests {
    private func parse(_ run: String) throws -> Config {
        try Config.parse("\(run)\n[tools]\navailable = [\"Read\"]\nallowed = [\"Read\"]\n")
    }

    private func problems(_ run: String) -> [String] {
        do {
            _ = try parse(run)
            return []
        } catch let error as ConfigError { return error.problems.map(\.message) } catch { return ["\(error)"] }
    }

    @Test func noTableMeansNoRun() throws {
        #expect(try parse("").run == nil)
    }

    @Test func aCommandWithAUrlCheck() throws {
        let run = try #require(
            try parse("[run]\ncommand = \"npm run dev:mock\"\nready_url = \"http://localhost:{port}/\"").run)
        #expect(run == RunConfig(command: "npm run dev:mock", ready: .url("http://localhost:{port}/")))
        #expect(run.readyTimeoutS == RunConfig.defaultReadyTimeoutS)
    }

    @Test func aCommandWithALineCheckAndATimeout() throws {
        let run = try #require(
            try parse("[run]\ncommand = \"scripts/mock.sh\"\nready_line = \"on mock data\"\nready_timeout_s = 300").run)
        #expect(run == RunConfig(command: "scripts/mock.sh", ready: .line("on mock data"), readyTimeoutS: 300))
    }

    @Test(arguments: [
        ("[run]\ncommand = \"a\"\nready_url = \"http://localhost:1/\"\nbogus = 1", "unknown key 'bogus' in [run]"),
        ("[run]\nready_line = \"x\"", "needs a 'command'"),
        ("[run]\ncommand = \"a\"", "needs 'ready_url' or 'ready_line'"),
        ("[run]\ncommand = \"a\"\nready_url = \"http://localhost:1/\"\nready_line = \"x\"", "not both"),
        ("[run]\ncommand = \"a && b\"\nready_line = \"x\"", "'command' must be a single plain command"),
        ("[run]\ncommand = \"a\"\nready_line = \"(\"", "regular expression"),
        ("[run]\ncommand = \"a\"\nready_line = \"\"", "regular expression"),
        ("[run]\ncommand = \"a\"\nready_url = \"https://localhost:1/\"", "'ready_url' must be an http URL"),
        ("[run]\ncommand = \"a\"\nready_url = \"http://example.com/\"", "must point at this machine"),
        ("[run]\ncommand = \"a\"\nready_line = \"x\"\nready_timeout_s = 0", "'ready_timeout_s'"),
        ("[run]\ncommand = \"a\"\nready_line = \"x\"\nready_timeout_s = 100000", "'ready_timeout_s'"),
        ("[run]\ncommand = 3\nready_line = \"x\"", "'command' must be a string"),
    ])
    func aBadTableIsRefusedWithTheKeyNamed(run: String, expected: String) {
        let found = problems(run)
        #expect(found.contains { $0.contains(expected) }, "\(found)")
    }
}
