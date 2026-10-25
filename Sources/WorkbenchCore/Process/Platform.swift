import Foundation

// Where macOS and Linux differ for the system calls and process facts Workbench uses. The rest of the code calls
// these and has no `#if`. The free functions also keep a type's own `open`/`close`/`read` from shadowing the libc one.

public func sysOpen(_ path: String, _ flags: Int32, _ mode: mode_t = 0) -> Int32 { open(path, flags, mode) }
func sysClose(_ fd: Int32) { _ = close(fd) }
func sysRead(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int { read(fd, buffer, count) }
func sysRename(_ from: String, _ to: String) -> Int32 { rename(from, to) }

extension stat {
    var modifiedTime: timespec {
        #if canImport(Darwin)
        st_mtimespec
        #else
        st_mtim
        #endif
    }

    var changedTime: timespec {
        #if canImport(Darwin)
        st_ctimespec
        #else
        st_ctim
        #endif
    }
}

extension siginfo_t {
    /// The child a `waitid` reported on (0 when `WNOHANG` found none).
    var childPID: pid_t {
        #if canImport(Darwin)
        si_pid
        #else
        _sifields._sigchld.si_pid
        #endif
    }
}

/// What the kernel knows about running processes: libproc on macOS, `/proc` on Linux.
enum ProcessTable {
    static func member(for pid: pid_t) -> ProcessMember? {
        #if canImport(Darwin)
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return ProcessMember(pid: pid, startSeconds: info.pbi_start_tvsec, startMicros: info.pbi_start_tvusec)
        #else
        // Field 22 (start time in clock ticks since boot) is index 19 after the command name.
        guard let fields = statFields(pid), fields.count > 19, let start = UInt64(fields[19]) else { return nil }
        return ProcessMember(pid: pid, startSeconds: start, startMicros: 0)
        #endif
    }

    static func parent(of pid: pid_t) -> pid_t? {
        #if canImport(Darwin)
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbi_ppid)
        #else
        guard let fields = statFields(pid), fields.count > 1 else { return nil }
        return pid_t(fields[1])
        #endif
    }

    /// The working directory as the kernel reports it (real path, so `/private/var` on macOS).
    static func workingDirectory(of pid: pid_t) -> String? {
        #if canImport(Darwin)
        var vnode = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vnode, size) == size else { return nil }
        return withUnsafeBytes(of: &vnode.pvi_cdir.vip_path) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        #else
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard readlink("/proc/\(pid)/cwd", &buffer, buffer.count - 1) > 0 else { return nil }
        return String(cString: buffer)
        #endif
    }

    static func allPIDs() -> [pid_t] {
        #if canImport(Darwin)
        let expected = proc_listallpids(nil, 0)
        guard expected > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(expected) + 32)
        let written = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard written > 0 else { return [] }
        return Array(pids.prefix(Int(written)))
        #else
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: "/proc")) ?? []
        return entries.compactMap { pid_t($0) }
        #endif
    }

    static func children(of parent: pid_t) -> [pid_t] {
        #if canImport(Darwin)
        let bytes = proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(parent), nil, 0)
        guard bytes > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(bytes) / MemoryLayout<pid_t>.size + 8)
        let written = proc_listpids(
            UInt32(PROC_PPID_ONLY), UInt32(parent), &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard written > 0 else { return [] }
        return pids.prefix(Int(written) / MemoryLayout<pid_t>.size).filter { $0 > 0 }
        #else
        return allPIDs().filter { self.parent(of: $0) == parent }
        #endif
    }

    #if !canImport(Darwin)
    /// `/proc/<pid>/stat` fields after the command name (which may hold spaces and parentheses): state, ppid, ...
    private static func statFields(_ pid: pid_t) -> [Substring]? {
        guard let text = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
            let close = text.lastIndex(of: ")")
        else { return nil }
        return text[text.index(after: close)...].split(separator: " ")
    }
    #endif
}
