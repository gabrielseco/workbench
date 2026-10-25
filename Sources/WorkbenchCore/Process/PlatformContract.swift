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
}
