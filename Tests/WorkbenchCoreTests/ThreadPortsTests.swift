import Foundation
import Testing

@testable import WorkbenchCore

/// A project's `threads/` directory of its own (with `worktrees/` beside it, as in `.workbench/`), so the blocks handed out
/// here are not the machine's.
private func threadsDirectory() throws -> URL {
    let url = Scratch.url("ports").resolvingSymlinksInPath().appendingPathComponent("threads")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// The thread has a worktree, which is what makes its block count: a thread without one holds nothing.
private func giveWorktree(_ directory: URL, _ id: String) {
    let worktree = directory.deletingLastPathComponent().appendingPathComponent("worktrees/\(id)")
    try? FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
}

/// The slot after `first`'s, wrapping past the end of the range, since a project may start at any slot.
private func nextFirst(_ first: Int) -> Int {
    let slot = (first - ThreadPorts.firstPort) / ThreadPorts.slotSize
    return ThreadPorts.firstPort + ((slot + 1) % ThreadPorts.slotCount) * ThreadPorts.slotSize
}

/// The first port of the slot a project starts at.
private func firstOf(_ directory: URL) -> Int {
    ThreadPorts.firstPort + ThreadPorts.startSlot(for: directory) * ThreadPorts.slotSize
}

private func assign(
    _ directory: URL, _ id: String, count: Int = 1, renew: Bool = false, isFree: @escaping (Int) -> Bool = { _ in true }
) -> ThreadPorts? {
    giveWorktree(directory, id)
    return ThreadPorts.assign(threadsDirectory: directory, id: id, count: count, renew: renew, isFree: isFree)
}

@Suite struct ThreadPortsTests {
    @Test func theFirstThreadGetsTheFirstBlockAndTheNextOneTheNextSlot() throws {
        let dir = try threadsDirectory()
        let a = try #require(assign(dir, "a"))
        let b = try #require(assign(dir, "b"))
        #expect(a.first == firstOf(dir), "the project's own starting slot")
        #expect(b.first == nextFirst(a.first), "a slot apart: a server stepping to the next port stays in its own")
    }

    @Test func aThreadKeepsItsPortsAcrossCallsAndRestarts() throws {
        let dir = try threadsDirectory()
        let first = try #require(assign(dir, "a", count: 2))
        _ = try #require(assign(dir, "b"))
        #expect(assign(dir, "a", count: 2) == first)
        #expect(ThreadPorts.read(dir.appendingPathComponent("a/ports.json")) == first, "it is on disk, not only in memory")
    }

    @Test func threadsMadeAtTheSameTimeNeverShareAPort() throws {
        let dir = try threadsDirectory()
        let ids = (0..<24).map { "t\($0)" }
        let box = Box()
        DispatchQueue.concurrentPerform(iterations: ids.count) { index in
            if let ports = assign(dir, ids[index], count: 3) { box.add(ports) }
        }
        let all = box.all
        #expect(all.count == ids.count)
        let used = all.flatMap(\.all)
        #expect(Set(used).count == used.count, "no port appears twice")
    }

    @Test func aPortSomethingElseHoldsIsSkippedNotHandedOut() throws {
        let dir = try threadsDirectory()
        let busy = firstOf(dir) + 1
        let ports = try #require(assign(dir, "a", count: 2, isFree: { $0 != busy }))
        #expect(ports.first == nextFirst(firstOf(dir)))
        #expect(!ports.all.contains(busy))
    }

    @Test func twoProjectsStartAtDifferentSlotsAndTheStartWrapsAroundTheRange() throws {
        let one = try threadsDirectory()
        // Two paths can land on the same slot (one in 800), so look for one that does not.
        var two = try threadsDirectory()
        for _ in 0..<20 where firstOf(two) == firstOf(one) { two = try threadsDirectory() }
        #expect(firstOf(one) != firstOf(two))
        // Every slot but the last one in line is taken (written directly, so the test stays fast).
        let start = ThreadPorts.startSlot(for: one)
        let last = (start + ThreadPorts.slotCount - 1) % ThreadPorts.slotCount
        for slot in 0..<ThreadPorts.slotCount where slot != last {
            let dir = one.appendingPathComponent("t\(slot)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            giveWorktree(one, "t\(slot)")
            let block = ThreadPorts(first: ThreadPorts.firstPort + slot * ThreadPorts.slotSize, count: 1)
            try JSONEncoder().encode(block).write(to: dir.appendingPathComponent("ports.json"))
        }
        let wrapped = try #require(assign(one, "late"))
        #expect(wrapped.first == ThreadPorts.firstPort + last * ThreadPorts.slotSize, "found past the end of the range")
        #expect(assign(one, "one-too-many") == nil, "a full range gives nil, not a port in use")
    }

    @Test func aThreadWithoutAWorktreeGivesItsBlockBackAndItsFileIsRemoved() throws {
        let dir = try threadsDirectory()
        let a = try #require(assign(dir, "a"))
        let file = dir.appendingPathComponent("a/ports.json")
        #expect(FileManager.default.fileExists(atPath: file.path))
        // Cleaned or abandoned: the folder stays as history, the worktree goes.
        try FileManager.default.removeItem(at: dir.deletingLastPathComponent().appendingPathComponent("worktrees/a"))
        let b = try #require(assign(dir, "b"))
        #expect(b.first == a.first, "the block is handed out again")
        #expect(!FileManager.default.fileExists(atPath: file.path), "and the stale file is gone")
    }

    @Test func aThreadWhosePortsAreHeldIsMovedWhenRenewedAndOthersAreLeftAlone() throws {
        let dir = try threadsDirectory()
        let a = try #require(assign(dir, "a", count: 2))
        let b = try #require(assign(dir, "b", count: 2))
        let held = Set(a.all)
        let moved = try #require(assign(dir, "a", count: 2, renew: true, isFree: { !held.contains($0) }))
        #expect(moved != a && !moved.overlaps(a) && !moved.overlaps(b))
        #expect(assign(dir, "a", count: 2) == moved, "the new block is the one kept")
        #expect(assign(dir, "b", count: 2) == b)
    }

    @Test func askingForMoreMovesToABlockThatFitsAndNeverOverlapsAnother() throws {
        let dir = try threadsDirectory()
        let a = try #require(assign(dir, "a", count: 1))
        let b = try #require(assign(dir, "b", count: 1))
        let bigger = try #require(assign(dir, "a", count: 4))
        #expect(bigger.count == 4)
        #expect(!bigger.overlaps(b))
        #expect(a.first != b.first)
        // Asking for fewer later keeps the block it has.
        #expect(assign(dir, "a", count: 2)?.first == bigger.first)
    }

    @Test func aDamagedFileIsReplacedAndAThreadWithNoFileGetsOne() throws {
        let dir = try threadsDirectory()
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("old"), withIntermediateDirectories: true)
        try "not json".write(to: dir.appendingPathComponent("old/ports.json"), atomically: true, encoding: .utf8)
        let ports = try #require(assign(dir, "old"))
        #expect(ports.first == firstOf(dir))
        try "{\"first\":80,\"count\":1}".write(
            to: dir.appendingPathComponent("old/ports.json"), atomically: true, encoding: .utf8)
        #expect(ThreadPorts.read(dir.appendingPathComponent("old/ports.json")) == nil, "a port outside the range is no block")
        for text in [
            "{\"first\":\(Int.max),\"count\":1}", "{\"first\":\(Int.max - 1),\"count\":10}",
            "{\"first\":\(ThreadPorts.firstPort),\"count\":\(Int.max)}", "{\"first\":-5,\"count\":-1}",
        ] {
            try text.write(to: dir.appendingPathComponent("old/ports.json"), atomically: true, encoding: .utf8)
            #expect(ThreadPorts.read(dir.appendingPathComponent("old/ports.json")) == nil, "\(text) is ignored, never a trap")
            #expect(assign(dir, "other") != nil, "and it does not stop the next allocation")
        }
    }

    @Test func noFreeBlockOrABadRequestGivesNilNeverAGuess() throws {
        let dir = try threadsDirectory()
        #expect(assign(dir, "a", isFree: { _ in false }) == nil)
        #expect(assign(dir, "a", count: 0) == nil)
        #expect(assign(dir, "a", count: ThreadPorts.maxCount + 1) == nil)
        #expect(assign(dir, "../escape") == nil)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("a/ports.json").path))
    }

    @Test func theEnvironmentNamesTheFirstPortTheOthersAndTheThread() {
        let env = ThreadPorts(first: 41_020, count: 3).environment(thread: "20261107-x")
        #expect(env["WORKBENCH_PORT"] == "41020" && env["PORT"] == "41020")
        #expect(env["WORKBENCH_PORT_1"] == "41021" && env["WORKBENCH_PORT_2"] == "41022")
        #expect(env["WORKBENCH_PORT_3"] == nil && env["WORKBENCH_THREAD"] == "20261107-x")
        #expect(ThreadPorts(first: 41_000, count: 1).environment(thread: "t")["WORKBENCH_PORT_1"] == nil)
    }

    @Test func isFreeSeesARealListener() throws {
        let port = try #require(AppLauncher.freePort())
        #expect(AppLauncher.isFree(port))
        let fd = socket(AF_INET, streamSocketType, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: UInt32(0x7f00_0001).bigEndian)
        address.sin_port = UInt16(port).bigEndian
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        try #require(bound == 0)
        try #require(listen(fd, 1) == 0)
        #expect(!AppLauncher.isFree(port))
    }

    @Test func thePortsKeyIsAWholeNumberFromOneToTheLimit() throws {
        func parse(_ line: String) throws -> Config {
            try Config.parse("\(line)\n[tools]\navailable = [\"Read\"]\nallowed = [\"Read\"]\n")
        }
        #expect(try parse("").ports == 1)
        #expect(try parse("ports = 3").ports == 3)
        for bad in ["ports = 0", "ports = \(ThreadPorts.maxCount + 1)", "ports = \"2\"", "ports = 1.5"] {
            #expect(throws: ConfigError.self, "\(bad)") { try parse(bad) }
        }
    }
}

private final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ThreadPorts] = []
    func add(_ ports: ThreadPorts) { lock.withLock { items.append(ports) } }
    var all: [ThreadPorts] { lock.withLock { items } }
}
