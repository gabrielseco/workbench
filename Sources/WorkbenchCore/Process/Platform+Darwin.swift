#if canImport(Darwin)
import Darwin
import Foundation

/// macOS: libproc for the process table, kqueue for the exit event, `CLOEXEC_DEFAULT` for descriptor hygiene.
struct DarwinPlatform: ProcessInspecting, SpawnPlatform, ExitNotifying, Subreaping, PipeReading {
    func member(for pid: pid_t) -> ProcessMember? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return ProcessMember(pid: pid, startSeconds: info.pbi_start_tvsec, startMicros: info.pbi_start_tvusec)
    }

    func parent(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbi_ppid)
    }

    func workingDirectory(of pid: pid_t) -> String? {
        var vnode = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vnode, size) == size else { return nil }
        return withUnsafeBytes(of: &vnode.pvi_cdir.vip_path) { raw -> String in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    func allPIDs() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let written = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard written > 0 else { return [] }
        return Array(pids.prefix(Int(written)))
    }

    func children(of parent: pid_t) -> [pid_t] {
        let bytes = proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(parent), nil, 0)
        guard bytes > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(bytes) / MemoryLayout<pid_t>.size + 8)
        let written = proc_listpids(
            UInt32(PROC_PPID_ONLY), UInt32(parent), &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard written > 0 else { return [] }
        return pids.prefix(Int(written) / MemoryLayout<pid_t>.size).filter { $0 > 0 }
    }

    var descriptorFlags: Int32 { Int32(POSIX_SPAWN_CLOEXEC_DEFAULT) }

    func addDescriptorHygiene(to actions: inout SpawnFileActions) -> Int32 { 0 }

    func watchExit(of pid: pid_t, queue: DispatchQueue, handler: @escaping @Sendable () -> Void) -> ExitWatch? {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        source.setEventHandler(handler: handler)
        source.resume()
        return ExitWatch { source.cancel() }
    }

    func becomeSubreaper() -> Bool { false }

    var orphanAdopters: Set<pid_t> { [1] }

    func watch(fd: Int32, queue: DispatchQueue, onReadable: @escaping @Sendable () -> Void) -> any PipeReader {
        DispatchPipeReader(fd: fd, queue: queue, onReadable: onReadable)
    }
}

/// A Dispatch read source: the closing of the descriptor is its cancel handler's job, after libdispatch has unregistered it.
private final class DispatchPipeReader: PipeReader, @unchecked Sendable {
    private let source: DispatchSourceRead

    init(fd: Int32, queue: DispatchQueue, onReadable: @escaping @Sendable () -> Void) {
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler(handler: onReadable)
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    func cancel() { source.cancel() }
}
#endif
