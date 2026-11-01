import Foundation
import Testing
import WorkbenchCore

@testable import WorkbenchApp

/// Preferences that count every read and write, so "untouched" means none at all, not just an unchanged value.
private final class SpyPreferences: Preferences, @unchecked Sendable {
    private(set) var reads = 0
    private(set) var writes = 0
    private var stored: String?

    init(_ stored: String? = nil) { self.stored = stored }

    var notificationsPaused: Bool {
        get {
            reads += 1
            return false
        }
        set {
            writes += 1
            _ = newValue
        }
    }

    var announcedAttention: [String] {
        get {
            reads += 1
            return []
        }
        set {
            writes += 1
            _ = newValue
        }
    }

    var seenAttention: [String] {
        get {
            reads += 1
            return []
        }
        set {
            writes += 1
            _ = newValue
        }
    }

    var recentProjects: [String] {
        get {
            reads += 1
            return []
        }
        set {
            writes += 1
            _ = newValue
        }
    }

    var projectPath: String? {
        get {
            reads += 1
            return stored
        }
        set {
            writes += 1
            stored = newValue
        }
    }
}

@MainActor @Suite struct LaunchOptionsTests {
    @Test func theLoginShellPathIsAskedForUnlessAnEnvironmentVariableSaysNot() {
        #expect(!LaunchOptions.from(environment: [:]).skipsLoginPath)
        #expect(!LaunchOptions.from(environment: ["WORKBENCH_APP_PROJECT": "/tmp/p"]).skipsLoginPath, "a fixture asks too")
        #expect(LaunchOptions.from(environment: ["WORKBENCH_SKIP_LOGIN_PATH": "1"]).skipsLoginPath)
        #expect(!LaunchOptions.from(environment: ["WORKBENCH_SKIP_LOGIN_PATH": ""]).skipsLoginPath)
    }

    @Test func thePathIsResolvedBeforeAnyProjectIsOpenedAndNotAtAllWhenTheSwitchIsSet() async throws {
        let fixture = try await AppFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let seen = Seen()
        var options = LaunchOptions.from(environment: ["WORKBENCH_APP_PROJECT": fixture.root.path])
        let store = ProjectStore(preferences: MemoryPreferences())
        await options.start(store) { seen.add("path, project open: \(store.project != nil)") }
        #expect(seen.all == ["path, project open: false"], "the PATH first, then the project: \(seen.all)")
        #expect(store.project != nil)

        options.skipsLoginPath = true
        let skipped = Seen()
        await options.start(ProjectStore(preferences: MemoryPreferences())) { skipped.add("called") }
        #expect(skipped.all.isEmpty)
    }

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

    @Test func aNamedProjectNeverReadsOrWritesTheRealPreferences() async throws {
        let fixture = try await AppFixture()
        try await fixture.addThread("t1", approved: true)
        let spy = SpyPreferences("/somewhere/remembered")
        let options = LaunchOptions(project: fixture.root)
        let store = options.makeStore(preferences: spy)
        await options.start(store)
        try fixture.turn("t1", 1)
        await store.refresh()
        await store.runDoctor()
        #expect(store.project == fixture.project)
        #expect(spy.reads == 0 && spy.writes == 0, "reads \(spy.reads), writes \(spy.writes)")
    }

    @Test func withNoProjectNamedTheRealPreferencesAreUsed() async throws {
        let fixture = try await AppFixture()
        try await fixture.addThread("t1", approved: true)
        let spy = SpyPreferences(fixture.project.root.path)
        let options = LaunchOptions(project: nil)
        let store = options.makeStore(preferences: spy)
        await options.start(store)
        #expect(spy.reads >= 1 && spy.writes >= 1, "the spy would have shown a restore and a save")
    }
}

private final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ item: String) { lock.withLock { items.append(item) } }
    var all: [String] { lock.withLock { items } }
}
