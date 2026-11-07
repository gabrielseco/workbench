import Foundation
import Testing

@testable import WorkbenchCore

@Suite struct ModelCatalogTests {
    @Test func everyNameIsOneConfigEditAcceptsAndFitsItsOwnProvider() throws {
        #expect(ModelCatalog.names(for: .claude) == ["opus", "sonnet", "haiku"])
        #expect(!ModelCatalog.names(for: .codex).isEmpty)
        for provider in AgentSetup.providers {
            let names = ModelCatalog.names(for: provider)
            #expect(Set(names).count == names.count, "no repeats in \(provider)")
            for name in names {
                try ConfigEdit.checkValue(name, for: ConfigEdit.Key(role: .run, field: .model))
                #expect(AgentSetup.modelFit(provider: provider, model: name) == nil, "\(name) on \(provider)")
            }
        }
    }

    @Test func noProviderOffersAnotherProvidersNames() {
        let claude = Set(ModelCatalog.names(for: .claude)), codex = Set(ModelCatalog.names(for: .codex))
        #expect(claude.isDisjoint(with: codex))
    }
}
