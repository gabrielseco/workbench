import Foundation
import Testing

struct ScratchTests {
    private func tmp() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("scratch-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func make(_ name: String, in dir: URL, age: TimeInterval = 0) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let date = Date().addingTimeInterval(-age)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        return url
    }

    @Test func aPathIsInsideThisProcessesRootAndNothingIsCreated() {
        let url = Scratch.url("probe")
        #expect(url.path.hasPrefix(Scratch.root.path + "/probe-"))
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(Scratch.root.lastPathComponent.hasPrefix("wb-scratch-\(getpid())-"))
    }

    @Test func aRootOfAProcessThatIsGoneIsRemovedAndALiveOneIsKept() throws {
        let dir = try tmp()
        defer { try? FileManager.default.removeItem(at: dir) }
        // pid 2^22 + 1 is above the kernel's pid limit on macOS, so no process has it.
        let dead = try make("wb-scratch-4194305-\(UUID().uuidString)", in: dir)
        let live = try make("wb-scratch-\(getpid())-\(UUID().uuidString)", in: dir)
        Scratch.sweepStale(in: dir)
        #expect(!FileManager.default.fileExists(atPath: dead.path))
        #expect(FileManager.default.fileExists(atPath: live.path))
    }

    @Test func aDirectoryOlderThanADayIsRemovedAndAFreshOneIsKept() throws {
        let dir = try tmp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = try make("wb-run-\(UUID().uuidString)", in: dir, age: 2 * 86_400)
        let fresh = try make("wb-run-\(UUID().uuidString)", in: dir, age: 60)
        let other = try make("keep-\(UUID().uuidString)", in: dir, age: 2 * 86_400)
        Scratch.sweepStale(in: dir)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
        #expect(FileManager.default.fileExists(atPath: other.path), "only wb-* is ours to remove")
    }
}
