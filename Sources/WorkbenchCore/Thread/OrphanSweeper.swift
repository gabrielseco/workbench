import Foundation

/// Finds processes a dead runner left behind: children of a worktree whose parent is gone (re-parented to
/// launchd) and whose working directory is still inside it, together with everything running beneath them
/// (an orphaned `claude`'s tool children still have a live parent: it). Only those are touched. A shell or
/// editor the user has open in the worktree has a live parent and is left alone.
enum OrphanSweeper {
    static func orphans(inside directory: URL) -> [ProcessMember] {
        // Not `resolvingSymlinksInPath()`: Foundation rewrites /private/var back to /var, but the kernel
        // reports a process's working directory with the real /private prefix.
        let prefix = realPath(directory)
        var roots: [ProcessMember] = []
        for pid in ProcessTable.allPIDs() where pid > 1 && pid != getpid() {
            guard ProcessTable.parent(of: pid) == 1, let cwd = ProcessTable.workingDirectory(of: pid),
                cwd == prefix || cwd.hasPrefix(prefix + "/"), let member = ProcessTable.member(for: pid)
            else { continue }
            roots.append(member)
        }

        // Whatever runs under an orphan is orphaned too, wherever it has since changed directory to.
        var found = roots
        var seen = Set(roots.map(\.pid))
        for root in roots {
            for member in ProcessTree.descendants(of: root.pid) where seen.insert(member.pid).inserted {
                found.append(member)
            }
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
        // Newest first, so children go before the parents that would otherwise re-parent them mid-sweep.
        let ordered = members.sorted { ($0.startSeconds, $0.startMicros) > ($1.startSeconds, $1.startMicros) }
        for member in ordered where ProcessTree.isAlive(member) { kill(member.pid, SIGKILL) }
        return members.map(\.pid)
    }
}
