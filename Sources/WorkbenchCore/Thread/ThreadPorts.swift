import Foundation

/// The ports one thread may use: the same for its run, its check and its setup, and different from every other thread's
/// (docs/plan/P23-concurrency.md, slice 1). Two threads that each start a dev server or a browser test would otherwise
/// take the same default port, or a port the kernel offered both a moment apart.
///
/// Ports are handed out in blocks of `slotSize` starting at `firstPort`, so a server that moves to the next port when its own
/// is taken (Vite, Next) stays inside its thread's block. The block is written to the thread's `ports.json` the first
/// time anything needs it and kept until the thread is cleaned, so a retry and a later turn see the same numbers.
///
/// Two projects on one machine share the range, so each starts looking at a slot of its own (from its path) and a slot whose
/// ports something is already listening on is passed over. A port taken after that (another project's app that landed on
/// the same slot) is met when the app starts: the thread is moved to a free block then, and says so.
public struct ThreadPorts: Codable, Equatable, Sendable {
    /// The first port of the block, and how many of its ports the thread was given (`ports` in the config).
    public var first: Int
    public var count: Int

    public static let firstPort = 41_000
    public static let slotSize = 10
    public static let slotCount = 800
    public static let maxCount = slotSize

    public var all: [Int] { (first..<(first + count)).map { $0 } }

    /// `WORKBENCH_PORT` and `PORT` are the first port; `WORKBENCH_PORT_1`, `_2`, … the ones after it. `WORKBENCH_THREAD` names the
    /// thread, so a project can derive its own per-thread names (a test database, a cache directory) from it.
    public func environment(thread: String) -> [String: String] {
        var env = extraEnvironment
        env["WORKBENCH_PORT"] = String(first)
        env["PORT"] = String(first)
        env["WORKBENCH_THREAD"] = thread
        return env
    }

    /// Only the ports after the first.
    var extraEnvironment: [String: String] {
        var env: [String: String] = [:]
        for (index, port) in all.enumerated() where index > 0 { env["WORKBENCH_PORT_\(index)"] = String(port) }
        return env
    }

    func overlaps(_ other: ThreadPorts) -> Bool {
        first < other.first + other.count && other.first < first + count
    }

    // MARK: Handing them out

    /// The thread's ports, made and recorded on the first call. Nil when the range has no free block left or the file cannot
    /// be written, and the caller then goes without (the run falls back to a port the kernel offers).
    ///
    /// The lock is on the threads directory itself, so no file is left behind and two threads made at once cannot be given the
    /// same block. `renew` gives the thread a new block even though it has one (its own ports are held by something else).
    /// `isFree` is injected for tests.
    public static func assign(
        threadsDirectory: URL, id: String, count wanted: Int, renew: Bool = false, isFree: ((Int) -> Bool)? = nil
    ) -> ThreadPorts? {
        let isFree = isFree ?? { AppLauncher.isFree($0) }
        guard (1...maxCount).contains(wanted), SafeNames.isThreadID(id) else { return nil }
        let fm = FileManager.default
        try? fm.createDirectory(at: threadsDirectory, withIntermediateDirectories: true)
        let lock = open(threadsDirectory.path, O_RDONLY | O_CLOEXEC)
        guard lock >= 0 else { return nil }
        defer { close(lock) }
        // Blocking: the section below is a directory listing and one small write.
        guard flock(lock, LOCK_EX) == 0 else { return nil }
        defer { flock(lock, LOCK_UN) }

        let own = threadsDirectory.appendingPathComponent(id).appendingPathComponent("ports.json")
        if !renew, let mine = read(own), mine.count >= wanted { return ThreadPorts(first: mine.first, count: wanted) }

        let taken = ((try? fm.contentsOfDirectory(atPath: threadsDirectory.path)) ?? [])
            .filter { $0 != id && SafeNames.isThreadID($0) }
            .compactMap { read(threadsDirectory.appendingPathComponent($0).appendingPathComponent("ports.json")) }
        let start = startSlot(for: threadsDirectory)
        for step in 0..<slotCount {
            let slot = (start + step) % slotCount
            let block = ThreadPorts(first: firstPort + slot * slotSize, count: wanted)
            guard !taken.contains(where: block.overlaps), block.all.allSatisfy(isFree) else { continue }
            guard let data = try? JSONEncoder().encode(block),
                (try? fm.createDirectory(at: own.deletingLastPathComponent(), withIntermediateDirectories: true)) != nil,
                (try? data.write(to: own, options: .atomic)) != nil
            else { return nil }
            return block
        }
        return nil
    }

    /// Where this project starts looking: a stable number from its threads directory's path (not `hashValue`, which changes
    /// with every launch), so one project's threads sit side by side and another project's are somewhere else.
    static func startSlot(for threadsDirectory: URL) -> Int {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in threadsDirectory.standardizedFileURL.path.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        return Int(hash % UInt64(slotCount))
    }

    /// A damaged or out-of-range file is no block: the next call makes a new one over it.
    static func read(_ url: URL) -> ThreadPorts? {
        guard let data = try? Data(contentsOf: url), let ports = try? JSONDecoder().decode(ThreadPorts.self, from: data),
            ports.first >= firstPort, ports.count >= 1, ports.count <= maxCount,
            ports.first + ports.count <= firstPort + slotCount * slotSize
        else { return nil }
        return ports
    }
}

extension ThreadStore {
    /// This thread's ports (`ThreadPorts`), `count` of them (the config's `ports`).
    public func ports(of id: String, count: Int) -> ThreadPorts? {
        ThreadPorts.assign(threadsDirectory: project.threadsDirectory, id: id, count: count)
    }
}
