import Foundation

public enum SpawnError: Error, Equatable, Sendable {
    case notExecutable(String)
    case launchFailed(String)
}

/// The only place in the codebase that starts a child process.
///
/// Uses `posix_spawn` with `POSIX_SPAWN_CLOEXEC_DEFAULT`, so the child holds exactly stdin, stdout and
/// stderr and nothing else. Foundation's `Process` leaves a window between fork and exec in which a child
/// shares our descriptors, including the event log's lock (docs/plan/P1-runner.md, rule 8). Nothing else
/// should call `Process`; `scripts/check-banned-apis.sh` enforces that.
enum Spawner {
    /// - Parameters:
    ///   - stdout, stderr: open descriptors in this process that become the child's 1 and 2. They are not
    ///     closed here; close your copies after the call.
    ///   - ownProcessGroup: the child leads a new process group, so signals sent to it do not reach us.
    static func spawn(
        executable: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: String,
        stdout: Int32,
        stderr: Int32,
        ownProcessGroup: Bool = true
    ) throws -> pid_t {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw SpawnError.notExecutable(executable)
        }

        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            throw SpawnError.launchFailed("posix_spawn_file_actions_init")
        }
        defer { posix_spawn_file_actions_destroy(&actions) }

        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else {
            throw SpawnError.launchFailed("posix_spawnattr_init")
        }
        defer { posix_spawnattr_destroy(&attributes) }

        // stdin is always /dev/null: nothing can ever wait for input from us.
        var rc = posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        if rc == 0 { rc = posix_spawn_file_actions_adddup2(&actions, stdout, 1) }
        if rc == 0 { rc = posix_spawn_file_actions_adddup2(&actions, stderr, 2) }
        if rc == 0 { rc = posix_spawn_file_actions_addchdir_np(&actions, workingDirectory) }
        guard rc == 0 else { throw SpawnError.launchFailed("file actions: \(String(cString: strerror(rc)))") }

        var flags = Int32(POSIX_SPAWN_CLOEXEC_DEFAULT) | Int32(POSIX_SPAWN_SETSIGDEF) | Int32(POSIX_SPAWN_SETSIGMASK)
        if ownProcessGroup { flags |= Int32(POSIX_SPAWN_SETPGROUP) }
        var defaults = sigset_t()
        sigfillset(&defaults)
        var mask = sigset_t()
        sigemptyset(&mask)
        rc = posix_spawnattr_setflags(&attributes, Int16(flags))
        if rc == 0 { rc = posix_spawnattr_setsigdefault(&attributes, &defaults) }
        if rc == 0 { rc = posix_spawnattr_setsigmask(&attributes, &mask) }
        if rc == 0, ownProcessGroup { rc = posix_spawnattr_setpgroup(&attributes, 0) }
        guard rc == 0 else { throw SpawnError.launchFailed("spawn attributes: \(String(cString: strerror(rc)))") }

        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        var pid: pid_t = 0
        let status = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
        guard status == 0 else {
            throw SpawnError.launchFailed("\(executable): \(String(cString: strerror(status)))")
        }
        return pid
    }
}

/// How a child ended.
public enum Termination: Equatable, Sendable {
    case exited(Int32)
    case signaled(Int32)
    /// The child is gone but its status could not be collected, because something else in the process
    /// reaped it first. Treated as an exit; a soak that sees this has found a second reaper.
    case lost

    init(waitStatus status: Int32) {
        let signal = status & 0x7f
        self = signal == 0 ? .exited((status >> 8) & 0xff) : .signaled(signal)
    }
}

/// Reports a child's exit without blocking a thread.
///
/// A kqueue process source gives prompt notice, but it is not enough on its own, and an earlier version
/// that trusted it hung under load. The event can arrive while the child is still exiting and not yet
/// waitable, and a child can be reaped by someone else before we ever look. So there is always a poll
/// behind it: 1 ms right after an event, 50 ms otherwise. A poll that finds no such child reports the
/// exit as `.lost` instead of waiting forever.
///
/// Exit is *peeked* first (`waitid` with `WNOWAIT`), so the child stays a zombie and its pid stays reserved
/// while the owner sweeps its process group; only then does the owner call `reap()`.
final class ChildExitWatcher: @unchecked Sendable {
    static let idleInterval: TimeInterval = 0.05
    static let afterEventInterval: TimeInterval = 0.001

    private let pid: pid_t
    private let queue: DispatchQueue
    private var source: DispatchSourceProcess?
    private var pollTimer: DispatchSourceTimer?
    private var onExit: (@Sendable () -> Void)?
    private var notified = false
    private var gone = false
    private var reaped = false

    /// `onExit` runs on `queue`, at most once, when the child has exited and is still unreaped (or is gone).
    init(pid: pid_t, queue: DispatchQueue, onExit: @escaping @Sendable () -> Void) {
        self.pid = pid
        self.queue = queue
        self.onExit = onExit

        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            // The child is exiting. It may not be waitable for a moment, so look again soon.
            schedulePoll(every: Self.afterEventInterval)
            check()
        }
        self.source = source
        source.resume()
        schedulePoll(every: Self.idleInterval)
        // The child may already have exited before the source existed.
        queue.async { [weak self] in self?.check() }
    }

    private func schedulePoll(every interval: TimeInterval) {
        guard !notified else { return }
        pollTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in self?.check() }
        timer.resume()
        pollTimer = timer
    }

    private func check() {
        guard !notified, !reaped else { return }
        var info = siginfo_t()
        let rc = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
        if rc == 0, info.si_pid == pid {
            fire(gone: false)
        } else if rc == -1, errno == ECHILD {
            fire(gone: true)
        }
        // Otherwise still running, or exiting: the poll will look again.
    }

    private func fire(gone: Bool) {
        notified = true
        self.gone = gone
        pollTimer?.cancel()
        pollTimer = nil
        let handler = onExit
        onExit = nil
        handler?()
    }

    /// Collects the exit status. Call once, after `onExit` fired. Never blocks: the child has exited.
    func reap() -> Termination {
        guard !reaped else { return .lost }
        reaped = true
        source?.cancel()
        source = nil
        pollTimer?.cancel()
        pollTimer = nil
        if gone { return .lost }
        var status: Int32 = 0
        var result: pid_t
        repeat { result = waitpid(pid, &status, 0) } while result == -1 && errno == EINTR
        guard result == pid else { return .lost }
        return Termination(waitStatus: status)
    }

    func cancel() {
        source?.cancel()
        source = nil
        pollTimer?.cancel()
        pollTimer = nil
        onExit = nil
    }
}

/// One process, identified so a recycled pid is never mistaken for it.
struct ProcessMember: Equatable, Hashable, Sendable {
    var pid: pid_t
    var startSeconds: UInt64
    var startMicros: UInt64
}

enum ProcessTree {
    /// Every descendant of `root` (children, their children, ...) that exists right now.
    static func descendants(of root: pid_t) -> [ProcessMember] {
        var found: [ProcessMember] = []
        var queue: [pid_t] = [root]
        var seen: Set<pid_t> = [root]
        while let parent = queue.popLast() {
            for child in children(of: parent) where seen.insert(child).inserted {
                if let member = member(for: child) { found.append(member) }
                queue.append(child)
            }
        }
        return found
    }

    static func member(for pid: pid_t) -> ProcessMember? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return ProcessMember(
            pid: pid, startSeconds: info.pbi_start_tvsec, startMicros: info.pbi_start_tvusec)
    }

    /// True while that exact process (same pid, same start time) is still around.
    static func isAlive(_ member: ProcessMember) -> Bool {
        guard let current = Self.member(for: member.pid) else { return false }
        return current == member
    }

    private static func children(of parent: pid_t) -> [pid_t] {
        let bytes = proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(parent), nil, 0)
        guard bytes > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(bytes) / MemoryLayout<pid_t>.size + 8)
        let written = proc_listpids(
            UInt32(PROC_PPID_ONLY), UInt32(parent), &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard written > 0 else { return [] }
        return pids.prefix(Int(written) / MemoryLayout<pid_t>.size).filter { $0 > 0 }
    }
}
