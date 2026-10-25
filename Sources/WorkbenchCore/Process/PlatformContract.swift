import Foundation

// What Workbench asks of the operating system about processes, in one place. The rest of the code calls
// `platform` (see Platform.swift) and has no `#if` for any of it; each OS supplies its own file
// (Platform+Darwin.swift, later Platform+Linux.swift). The contract tests run the same checks on whichever one is
// in use, so a new platform is correct when they pass.

/// One process, identified so a recycled pid is never mistaken for it. `startSeconds` and `startMicros` are the start
/// time as the platform reports it: seconds and microseconds on macOS, clock ticks since boot (and 0) on Linux. They are
/// only ever compared for equality or ordered, and written to `runner.json`, so the unit does not matter to callers.
struct ProcessMember: Equatable, Hashable, Sendable {
    var pid: pid_t
    var startSeconds: UInt64
    var startMicros: UInt64
}

/// What the kernel knows about running processes.
protocol ProcessInspecting {
    /// The process with this pid, or nil when there is none right now.
    func member(for pid: pid_t) -> ProcessMember?
    func parent(of pid: pid_t) -> pid_t?
    /// The working directory as the kernel reports it: the real path, so `/private/var/...` on macOS.
    func workingDirectory(of pid: pid_t) -> String?
    func allPIDs() -> [pid_t]
    /// Direct children only.
    func children(of pid: pid_t) -> [pid_t]
}

// The spawn types are optional pointers on macOS and plain structs on glibc; this is the one place that says so.
#if canImport(Darwin)
typealias SpawnFileActions = posix_spawn_file_actions_t?
typealias SpawnAttributes = posix_spawnattr_t?
var emptySpawnFileActions: SpawnFileActions { nil }
var emptySpawnAttributes: SpawnAttributes { nil }
#else
typealias SpawnFileActions = posix_spawn_file_actions_t
typealias SpawnAttributes = posix_spawnattr_t
var emptySpawnFileActions: SpawnFileActions { posix_spawn_file_actions_t() }
var emptySpawnAttributes: SpawnAttributes { posix_spawnattr_t() }
#endif

/// How a child is started so that it holds exactly stdin, stdout and stderr and nothing else.
protocol SpawnPlatform {
    /// Extra `posix_spawn` flags (macOS: `POSIX_SPAWN_CLOEXEC_DEFAULT`, which makes every other descriptor close on exec).
    var descriptorFlags: Int32 { get }
    /// Whatever else the platform needs among the file actions, after the dup2s (Linux: close everything above 2).
    /// Returns 0, or the error number.
    func addDescriptorHygiene(to actions: inout SpawnFileActions) -> Int32
}

/// A handle on a platform's fast path for noticing a child's exit; `cancel()` stops it.
struct ExitWatch {
    let cancel: () -> Void
}

/// A prompt notice of a child's exit, where the platform has one. It is only ever a hint: `ChildExitWatcher` polls
/// behind it, because an event can arrive before the child is waitable and a child can be reaped by someone else.
protocol ExitNotifying {
    /// Calls `handler` on `queue` when `pid` exits. Nil when the platform has no such event; polling alone then.
    func watchExit(of pid: pid_t, queue: DispatchQueue, handler: @escaping @Sendable () -> Void) -> ExitWatch?
}

/// Adoption of orphans: on Linux a process whose parent died goes to the nearest ancestor that asked to be a
/// subreaper, not always to PID 1.
protocol Subreaping {
    /// True when this process now adopts the orphans beneath it. macOS has no such thing and says false.
    func becomeSubreaper() -> Bool

    /// The pids that adopt a process whose parent has died, as seen from this process: PID 1 on macOS, and on Linux PID 1
    /// or the nearest ancestor that is a subreaper (a user's `systemd --user`, a supervisor, a container's init). A
    /// leftover of a runner that was killed has one of these as its parent; a shell the user has open has a live parent
    /// that is not one of them, which is how the two are told apart.
    var orphanAdopters: Set<pid_t> { get }
}

/// A running watch on a pipe's read end, from `PipeReading.watch`.
protocol PipeReader: AnyObject, Sendable {
    /// Stops the callbacks and closes the descriptor, once, after the last callback has finished. Safe to call again, and
    /// from inside `onReadable`.
    func cancel()
}

/// Tells the engine on a queue when a pipe has data or has hung up. macOS uses a Dispatch read source. Linux cannot:
/// libdispatch there crashes (in `_dispatch_source_refs_finalize_unregistration`, on its manager thread) when a read
/// source is cancelled as an event for it arrives, which is what a child closing its end and us cancelling at EOF is. Under
/// 48 concurrent loops of pipe, write, close, cancel it fell over in about one four-minute run in two, and never in timers
/// or exit watchers alone (docs/plan/P18-linux.md).
protocol PipeReading {
    /// Starts watching `fd` (a non-blocking read end) and calls `onReadable` on `queue` while it has data or has hung up,
    /// until `cancel()`. The watch owns the descriptor from here on and closes it when it ends.
    func watch(fd: Int32, queue: DispatchQueue, onReadable: @escaping @Sendable () -> Void) -> any PipeReader
}
