import Foundation
import Testing
import WorkbenchCore

@testable import WorkbenchApp

@MainActor @Suite struct LaunchOptionsTests {
    @Test func theProjectComesFromTheEnvironmentOrNotAtAll() {
        #expect(LaunchOptions.from(environment: [:]).project == nil)
        #expect(LaunchOptions.from(environment: ["WORKBENCH_APP_PROJECT": ""]).project == nil)
        let named = LaunchOptions.from(environment: ["WORKBENCH_APP_PROJECT": "/tmp/some project"])
        #expect(named.project == URL(fileURLWithPath: "/tmp/some project"))
    }

    @Test func aNamedProjectOpensWithoutReadingOrWritingThePreferences() async throws {
        let fixture = try await AppFixture()
        try await fixture.addThread("t1", approved: true)
        let other = try await AppFixture()
        try await other.addThread("remembered", approved: true)
        let real = MemoryPreferences(projectPath: other.project.root.path)
        let options = LaunchOptions(project: fixture.root)
        let store = options.makeStore(preferences: real)
        await options.start(store)
        guard case .thread(let shown) = store.screen else {
            Issue.record("\(store.screen)")
            return
        }
        #expect(shown.id == "t1" && store.project == fixture.project, "the named project, not the remembered one")
        #expect(real.projectPath == other.project.root.path, "what a person set is untouched")
    }

    @Test func withNoProjectNamedTheRememberedOneIsRestored() async throws {
        let fixture = try await AppFixture()
        try await fixture.addThread("t1", approved: true)
        let real = MemoryPreferences(projectPath: fixture.project.root.path)
        let options = LaunchOptions(project: nil)
        let store = options.makeStore(preferences: real)
        await options.start(store)
        #expect(store.project == fixture.project)
    }

    @Test func aNamedProjectThatIsNotARepositoryShowsTheErrorAndSavesNothing() async throws {
        let elsewhere = try await AppFixture(git: false, workbench: false)
        let real = MemoryPreferences()
        let options = LaunchOptions(project: elsewhere.root)
        let store = options.makeStore(preferences: real)
        await options.start(store)
        #expect(store.screen == .notAGitRepository(path: elsewhere.root.path) && real.projectPath == nil)
    }
}
