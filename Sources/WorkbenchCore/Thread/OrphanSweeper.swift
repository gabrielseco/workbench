import Foundation

/// Finds processes a dead runner left behind: children of a worktree whose parent is gone (re-parented to
/// launchd) and whose working directory is still inside it. Only those are touched. A shell or editor the
/// user has open in the worktree has a live parent and is left alone.
enum OrphanSweeper {
    static func orphans(inside directory: URL) -> [ProcessMember] {
        // Not `resolvingSymlinksInPath()`: Foundation rewrites /private/var back to /var, but the kernel
        // reports a process's working directory with the real /private prefix.
        let prefix = realPath(directory)
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let written = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard written > 0 else { return [] }

        var found: [ProcessMember] = []
        for pid in pids.prefix(Int(written)) where pid > 1 && pid != getpid() {
            var bsd = proc_bsdinfo()
            let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, bsdSize) == bsdSize, bsd.pbi_ppid == 1
            else { continue }

            var vnode = proc_vnodepathinfo()
            let vnodeSize = Int32(MemoryLayout<proc_vnodepathinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vnode, vnodeSize) == vnodeSize else { continue }
            let cwd = withUnsafeBytes(of: &vnode.pvi_cdir.vip_path) { raw -> String in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            guard cwd == prefix || cwd.hasPrefix(prefix + "/") else { continue }
            found.append(
                ProcessMember(pid: pid, startSeconds: bsd.pbi_start_tvsec, startMicros: bsd.pbi_start_tvusec))
        }
        return found
    }

    static func realPath(_ url: URL) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(url.path, &buffer) != nil else { return url.path }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// SIGKILLs what `orphans(inside:)` finds and returns their pids.
    @discardableResult
    static func sweep(inside directory: URL) -> [pid_t] {
        let members = orphans(inside: directory)
        for member in members where ProcessTree.isAlive(member) { kill(member.pid, SIGKILL) }
        return members.map(\.pid)
    }
}
