import Foundation
import Testing

@testable import WorkbenchApp
@testable import WorkbenchCore

@MainActor private var keptFixtures: [AppFixture] = []

@MainActor @Suite struct HerdrStoreTests {
    private func store(
        found: Bool, opened: HerdrOpened = .worktree(workspace: "w1", alreadyOpen: false), error: Error? = nil
    ) async throws -> ProjectStore {
        let fixture = try await AppFixture()
        try await fixture.addThread("t1", approved: true)
        keptFixtures.append(fixture)
        let actions = GoalActions(
            herdrFound: { _ in found },
            openInHerdr: { _, _ in
                if let error { throw error }
                return opened
            })
        let store = ProjectStore(preferences: MemoryPreferences(projectPath: nil), actions: actions)
        #expect(await store.open(fixture.root))
        return store
    }

    private static func folder(_ how: String) -> String {
        "Herdr would not open it as a git worktree, so the folder is \(how) as a plain workspace."
    }

    @Test func theButtonIsOfferedOnlyWhereAHerdrWasFound() async throws {
        #expect(try await store(found: true).herdrFound)
        #expect(try await !store(found: false).herdrFound)
    }

    @Test func eachWayItOpenedSaysSo() async throws {
        let cases: [(HerdrOpened, String)] = [
            (.worktree(workspace: "w1", alreadyOpen: false), "Opened in Herdr."),
            (.worktree(workspace: "w1", alreadyOpen: true), "Herdr already had it open: brought forward."),
            (.folder(workspace: "w2", alreadyOpen: false), Self.folder("opened")),
            (.folder(workspace: "w2", alreadyOpen: true), Self.folder("brought forward")),
        ]
        for (opened, note) in cases {
            let store = try await store(found: true, opened: opened)
            await store.openInHerdr()
            #expect(store.actionNote == note && store.actionError == nil)
        }
    }

    @Test func anErrorIsTheErrorLineAndNothingElse() async throws {
        let failure = HerdrFailure(code: "timeout", message: "herdr did not answer within 10 seconds")
        let store = try await store(found: true, error: failure)
        await store.openInHerdr()
        #expect(store.actionError == "herdr did not answer within 10 seconds" && store.actionNote == nil)
        #expect(store.busy == nil && !store.runningHere)
    }
}
