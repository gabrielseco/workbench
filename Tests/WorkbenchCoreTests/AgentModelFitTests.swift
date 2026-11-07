import Foundation
import Testing

@testable import WorkbenchCore

@Suite struct AgentModelFitTests {
    @Test func aNameThatBelongsToTheOtherProviderIsFlagged() {
        for name in ["opus", "sonnet", "haiku", "claude-opus-5-5", "sonnet[1m]", "Opus"] {
            #expect(AgentSetup.modelFit(provider: .codex, model: name) == .claude, "\(name) on codex")
            #expect(AgentSetup.modelFit(provider: .claude, model: name) == nil, "\(name) on claude")
        }
        for name in ["gpt-6.1-terra", "gpt-5", "o3", "o4-mini", "GPT-5"] {
            #expect(AgentSetup.modelFit(provider: .claude, model: name) == .codex, "\(name) on claude")
            #expect(AgentSetup.modelFit(provider: .codex, model: name) == nil, "\(name) on codex")
        }
    }

    @Test func aNameItDoesNotKnowIsNeverFlagged() {
        for name in ["my-finetune", "gemini-3", "opusx", "omega", "o", "sonnets"] {
            #expect(AgentSetup.modelFit(provider: .claude, model: name) == nil, "\(name)")
            #expect(AgentSetup.modelFit(provider: .codex, model: name) == nil, "\(name)")
        }
    }
}
