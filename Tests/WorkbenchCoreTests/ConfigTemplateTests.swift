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
        #expect(config.agents.run.model == "opus" && config.agents.ship.model == "haiku")
        #expect(config.agents.plan.model == "opus")
        #expect(Config.exampleTOML.contains("[agents.judge]") && Config.exampleTOML.contains("review.stage.<name>"))
    }

    @Test func theTemplateMentionsAutoAdvanceAndItParsesOnceUncommented() throws {
        let line = try #require(Config.exampleTOML.split(separator: "\n").first { $0.contains("# auto_advance = true") })
        #expect(line.contains("auto") && line.contains("pr-review"))
        let uncommented = line.replacingOccurrences(of: "# auto_advance", with: "auto_advance")
        let config = try Config.parse("[tools]\navailable = [\"Read\"]\n[review]\n\(uncommented)\n")
        #expect(config.review.autoAdvance)
    }
}
