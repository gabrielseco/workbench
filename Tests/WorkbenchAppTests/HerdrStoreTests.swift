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

    @Test func theRealGateShowsTheButtonOnlyForAHerdrThatIsThere() async throws {
        let fixture = try await AppFixture()
        keptFixtures.append(fixture)
        let project = fixture.project
        try FileManager.default.createDirectory(
            at: project.configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let stub = fixture.root.appendingPathComponent("stand-in.sh")
        try "#!/bin/sh\n".write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        func write(_ herdr: String) throws {
            try "herdr = \"\(herdr)\"\n[tools]\navailable = [\"Read\"]\n".write(
                to: project.configURL, atomically: true, encoding: .utf8)
        }
        try write(stub.path)
        #expect(GoalActions.core.herdrFound(project))
        // Named, but not there: no button (and no falling back to a herdr that is).
        try write(fixture.root.appendingPathComponent("gone").path)
        #expect(!GoalActions.core.herdrFound(project))
    }

    @Test func aConfigThatDoesNotLoadNeverFallsBackToTheRealHerdr() async throws {
        let fixture = try await AppFixture()
        keptFixtures.append(fixture)
        let project = fixture.project
        try FileManager.default.createDirectory(
            at: project.configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let marker = fixture.root.appendingPathComponent("stand-in-ran")
        let stub = fixture.root.appendingPathComponent("stand-in.sh")
        try "#!/bin/sh\ntouch '\(marker.path)'\n".write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        // The stand-in is named, but another key is wrong: the file does not load.
        try "herdr = \"\(stub.path)\"\nnot_a_key = 1\n[tools]\navailable = [\"Read\"]\n".write(
            to: project.configURL, atomically: true, encoding: .utf8)
        #expect(GoalActions.core.herdrFound(project), "the button stays, so the click can say why")
        do {
            _ = try await GoalActions.core.openInHerdr(project, "t1")
            Issue.record("a config that does not load still ran a herdr")
        } catch {
            #expect("\(error)".contains("does not load"))
        }
        #expect(!FileManager.default.fileExists(atPath: marker.path), "the stand-in ran")
        // With the config fixed, the same key finds the stand-in.
        try "herdr = \"\(stub.path)\"\n[tools]\navailable = [\"Read\"]\n".write(
            to: project.configURL, atomically: true, encoding: .utf8)
        #expect(try GoalActions.herdrExecutable(project)?.path == stub.path)
    }
}
