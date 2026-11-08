import Foundation
import Testing

@testable import WorkbenchCore

@Suite struct MaxActiveThreadsConfigTests {
    private let tools = "\n[tools]\navailable = [\"Read\"]\n"

    @Test func oneIsTheDefault() throws {
        #expect(try Config.parse(tools).maxActiveThreads == 1)
    }

    @Test func aWholeNumberUpToTheLimitIsKept() throws {
        #expect(try Config.parse("max_active_threads = 3\n" + tools).maxActiveThreads == 3)
        let limit = Config.maxActiveThreadsLimit
        #expect(try Config.parse("max_active_threads = \(limit)\n" + tools).maxActiveThreads == limit)
    }

    @Test func anythingElseIsAConfigError() {
        for bad in ["0", "-1", "\(Config.maxActiveThreadsLimit + 1)", "\"3\"", "2.5"] {
            #expect(throws: ConfigError.self) { _ = try Config.parse("max_active_threads = \(bad)\n" + tools) }
        }
    }
}

@Suite struct MaxActiveThreadsAdmissionTests {
    @Test func creatingAtOnceNeverPassesTheCap() async throws {
        for round in 0..<5 {
            let root = Scratch.url("admit\(round)").resolvingSymlinksInPath()
            let workbench = root.appendingPathComponent(".workbench")
            try FileManager.default.createDirectory(at: workbench, withIntermediateDirectories: true)
            let store = ThreadStore(project: Project(root: root))
            let made = await withTaskGroup(of: Bool.self) { group in
                for index in 0..<8 {
                    group.addTask { (try? store.create(id: "g-20261108-t\(index)", maxActive: 3)) != nil }
                }
                return await group.reduce(0) { $0 + ($1 ? 1 : 0) }
            }
            #expect(made == 3, "eight at once, three slots (round \(round))")
            #expect(store.threadIDs().count == 3)
        }
    }

    @Test func aChatIsFoundByItsWholeName() {
        // The ids the service makes: the day is `yyyy-MM-dd`.
        let day = DateFormatter.dayStamp.string(from: Date())
        #expect(ThreadStore.chatName(of: "g-\(day)-foo") == "foo")
        #expect(ThreadStore.chatName(of: "g-\(day)-bar-foo") == "bar-foo")
        #expect(ThreadStore.chatName(of: "g-\(day)-2-foo") == "2-foo", "a name that starts with a digit stays whole")
        #expect(ThreadStore.chatName(of: "g-\(day)-bar-foo") != "foo", "a tail of the name is not the name")
        #expect(ThreadStore.chatName(of: "other") == nil)
        #expect(ThreadStore.chatName(of: "g-\(day)") == nil)
    }
}

@Suite(.processGate) struct MaxActiveThreadsTests {
    private func config(_ n: Int) throws -> Config {
        try Config.parse("max_active_threads = \(n)\n[tools]\navailable = [\"Read\"]\n")
    }

    @Test func threadsFillTheSlotsAndTheNextIsRefusedNamingThem() async throws {
        let fx = try await RunnerFixture()
        let config = try config(3)
        var ids: [String] = []
        for name in ["one", "two", "three"] {
            ids.append(try await fx.service.newThread(name: name, base: "main", config: config))
        }
        #expect(Set(ids).count == 3, "three threads, each with its own id")

        do {
            _ = try await fx.service.newThread(name: "four", base: "main", config: config)
            Issue.record("expected the cap to refuse a fourth")
        } catch let error as ThreadStoreError {
            guard case .tooManyActive(let named, let max) = error else {
                Issue.record("got \(error)")
                return
            }
            #expect(max == 3)
            #expect(Set(named) == Set(ids))
            #expect(error.description.contains("max_active_threads"))
        }
        let folders = ThreadStore(project: fx.project).threadIDs()
        #expect(folders.count == 3, "the refusal left no fourth folder")
    }

    @Test func endingAThreadFreesItsSlot() async throws {
        let fx = try await RunnerFixture()
        let config = try config(2)
        let first = try await fx.service.newThread(name: "one", base: "main", config: config)
        _ = try await fx.service.newThread(name: "two", base: "main", config: config)
        try await fx.service.abandon(id: first)

        let third = try await fx.service.newThread(name: "three", base: "main", config: config)
        #expect(ThreadStore(project: fx.project).activeThreadIDs().contains(third))
        #expect(!ThreadStore(project: fx.project).activeThreadIDs().contains(first))
    }

    @Test func theDefaultStillAllowsOneThread() async throws {
        let fx = try await RunnerFixture()
        let first = try await fx.service.newThread(name: "one", base: "main")
        await #expect(throws: ThreadStoreError.activeThreadExists(first)) {
            _ = try await fx.service.newThread(name: "two", base: "main", config: try config(1))
        }
    }

    @Test func activeThreadsComeNewestFirst() async throws {
        let fx = try await RunnerFixture()
        let config = try config(3)
        let old = try await fx.service.newThread(name: "old", base: "main", config: config)
        try await Task.sleep(for: .milliseconds(1100))  // createdAt has a one second resolution
        let new = try await fx.service.newThread(name: "new", base: "main", config: config)
        let store = ThreadStore(project: fx.project)
        #expect(store.activeThreadIDs() == [new, old])
        #expect(store.newestActiveThreadID() == new)
    }

    @Test func aFlowThatMayAbandonOnlyEverMeetsTheSingleThread() async throws {
        let fx = try await RunnerFixture()
        let store = ThreadStore(project: fx.project)
        #expect(try store.blockingThread(maxActive: 1) == nil, "a slot is free")

        let first = try await fx.service.newThread(name: "one", base: "main", config: try config(2))
        #expect(try store.blockingThread(maxActive: 1) == first)
        #expect(try store.blockingThread(maxActive: 2) == nil)

        let second = try await fx.service.newThread(name: "two", base: "main", config: try config(2))
        #expect(throws: ThreadStoreError.tooManyActive([second, first], max: 2)) { _ = try store.blockingThread(maxActive: 2) }
    }
}
