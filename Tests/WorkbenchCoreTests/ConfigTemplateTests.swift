import Foundation
import Testing

@testable import WorkbenchCore

@Suite struct ConfigTemplateTests {
    @Test func theProviderAndAgentExamplesParseOnceUncommented() throws {
        let lines = Config.exampleTOML.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let start = try #require(lines.firstIndex { $0.hasPrefix("# [providers.codex]") })
        let end = try #require(lines.firstIndex { $0.hasPrefix("# allow_unpriced") })
        let block = lines[start...end].map { line -> String in
            let text = line.hasPrefix("# ") ? String(line.dropFirst(2)) : line
            return text
        }
        let config = try Config.parse(block.joined(separator: "\n") + "\n[tools]\navailable = [\"Read\"]\n")
        #expect(config.executable(for: .codex) == "/opt/homebrew/bin/codex")
        #expect(config.agents.judge.model == "sonnet" && config.agents.review.allowUnpriced == true)
        #expect(Config.exampleTOML.contains("[agents.judge]") && Config.exampleTOML.contains("review.stage.<name>"))
    }
}
