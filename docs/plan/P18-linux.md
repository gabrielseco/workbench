# P18: Linux

Status: plan, nothing built. Written 2026-10-25. Starts from the throwaway probe in PR #221 (`probe/linux-build`),
which ports the package to Linux in one 40-file diff and is not for merge. This phase ships the same result as
small PRs and keeps Linux green afterwards. Complements [P17](P17-faster-tests.md) (the Linux job must not slow the
gate) and [`../later/portability.md`](../later/portability.md) (other stacks, not other operating systems).

## Why

Workbench runs on macOS 14+ only. Linux would let CI run on cheaper runners, let the soak and leftover-process checks
run on a second kernel, and let Workbench run on a server. The probe shows the code needs few changes; what is
missing is a way to keep two platforms correct without `#if` spread through the code.

## What the probe changed (and what that tells us)

| Area | macOS only | Linux replacement |
|---|---|---|
| Hashing | `CryptoKit` (6 files) | `swift-crypto`: same API, wraps CryptoKit on Apple platforms |
| gzip | `Compression` | system zlib through a `CZlib` system-library target |
| Process facts | `libproc` (`proc_pidinfo`, `proc_listpids`, cwd) | `/proc/<pid>/stat`, `/proc/<pid>/cwd`, `/proc` listing |
| Spawn | `POSIX_SPAWN_CLOEXEC_DEFAULT` | `posix_spawn_file_actions_addclosefrom_np(3)` |
| Exit notification | `DispatchSourceProcess` (kqueue) | none; the poll timer and `waitid` already back it up |
| Ready check | `Network.framework` | BSD sockets |
| stat/siginfo fields | `st_mtimespec`, `si_pid` | `st_mtim`, `_sifields._sigchld.si_pid` |
| `stdout` | readable | Swift 6 rejects the glibc global; a one-line C shim |

## What the probe does not settle

Compiling is not the same as behaving. Open points, all from review of #221:

1. **The probe runs on its branch only.** It does not run the soak or the leftover-process checks, and its container
   is root, so a permission test is skipped.
2. **`#if` sits inside function bodies.** Two implementations cannot be read, or tested, as wholes.
3. **`OrphanSweeper` assumes an orphan has parent PID 1.** On Linux a process is adopted by the nearest ancestor
   subreaper (a supervisor, a container init, `systemd --user`), so a survivor can be missed.
4. **The new ready check is bounded by a deadline only after `getaddrinfo`**, which is synchronous and unbounded.
   Readiness URLs are loopback only, so the resolver is not needed. IPv6 hosts are not normalised and the
   fragmented-response, early-close, timeout and cancel cases have no test.
5. **A process start identity differs**: microseconds on macOS, clock ticks since boot on Linux
   (`startMicros` is always 0). Callers only compare it, so it should be one opaque value.

## Design

A small contract, two implementations, shared logic with no `#if`. No plugin framework, no other language.

```
Sources/WorkbenchCore/Process/
  PlatformContract.swift   protocols and value types
  Platform.swift           the only selector: typealias CurrentPlatform, plus the sys* wrappers
  Platform+Darwin.swift    whole file in #if canImport(Darwin)
  Platform+Linux.swift     whole file in #if !canImport(Darwin)
  Spawner.swift, ProcessTree.swift, OrphanSweeper.swift, ChildExitWatcher.swift   shared
```

```swift
protocol ProcessInspecting {
    func member(for pid: pid_t) -> ProcessMember?   // pid plus an opaque start token
    func parent(of pid: pid_t) -> pid_t?
    func workingDirectory(of pid: pid_t) -> String?
    func allPIDs() -> [pid_t]
    func children(of pid: pid_t) -> [pid_t]
}
protocol SpawnPlatform {      // descriptor hygiene: the child inherits only 0, 1 and 2
    func configure(_ actions: inout posix_spawn_file_actions_t, _ flags: inout Int32,
                   _ attributes: inout posix_spawnattr_t) throws
}
protocol ExitNotifying {      // fast path only; polling stays the source of truth
    func watch(pid: pid_t, queue: DispatchQueue, onEvent: @escaping @Sendable () -> Void) -> Cancellable?
}
protocol Subreaping {         // Darwin: false. Linux: prctl(PR_SET_CHILD_SUBREAPER)
    func becomeSubreaper() -> Bool
}
```

`ProcessMember` holds `pid` and one `start: UInt64` token. Pure parsing (`/proc/<pid>/stat` fields, which may hold
spaces and parentheses in the command name) is a plain function so macOS CI can test it with fixtures.

**Orphans.** Ownership no longer depends on the parent PID. An orphan is a process whose working directory is inside
the worktree and which is not a descendant of a live Workbench process. That holds on both kernels, under PID 1 and
under any subreaper. Workbench may also call `becomeSubreaper()` at startup on Linux so its own orphans come to it;
the cwd rule is what recovery relies on after a restart.

**Ready check.** A `LoopbackProbe` accepts only `127.0.0.1`, `::1` and `localhost` (mapped to both literals), parses
them with `inet_pton` after stripping the brackets of an IPv6 URL host, connects non-blocking and waits only through
`poll` against one deadline. No `getaddrinfo`.

## Tasks (one PR each)

| # | PR | Notes |
|---|---|---|
| 1 | **Portable libraries**: `swift-crypto` for the six `CryptoKit` imports, system zlib for `Gzip` (`CZlib`), `Package.resolved` committed | Behaviour identical on macOS; the existing hash and gzip tests are the proof. `zcat` and `gzip -t` must still read what is written. |
| 2 | **Platform contract, macOS only**: the four protocols, `Platform+Darwin.swift` (today's libproc code moved, not changed), `ProcessMember` with an opaque start token, `Spawner`, `ProcessTree` and `OrphanSweeper` call through it | Refactor, no behaviour change. Adds the contract tests (below), run on the current platform. |
| 3 | **Linux implementation**: `Platform+Linux.swift`, `CShim`, the `stat`/`siginfo_t` accessors, `Glibc` imports, fake-claude and test fixes, a Linux build job | Builds and passes the whole suite in a `swift:6.2` container with `--init`. |
| 4 | **Orphan ownership**: the cwd-and-not-a-descendant rule replaces `ppid == 1`; `becomeSubreaper()` called at startup | Test under a subreaper (a parent that sets `PR_SET_CHILD_SUBREAPER` and runs the CLI) and under PID 1. |
| 5 | **Loopback ready check**: `LoopbackProbe` replaces `Network.framework` | Tests: response split across packets, early close, timeout, cancel, IPv6 literal, a name that does not resolve. |
| 6 | **Linux as a permanent gate**: the job runs on every PR, runs the soak and the leftover-process checks, and runs once as a non-root user | Decide the runner and cost; lint already moved to Linux in #219. Keep wall time under the macOS job (P17). |

Tasks 1 and 2 are independent of each other and of Linux. 3 needs 1 and 2. 4 and 5 can follow 3 in either order;
6 comes last but may start as soon as 3 lands, with the soak added when 4 is in.

## Contract tests

One generic suite, `contract(_ platform: some ProcessInspecting & SpawnPlatform)`, run on the current platform in CI.
It spawns `fake-claude` and checks:

- `member` is stable for one process and differs after the pid is reused;
- `children` finds a grandchild that moved into its own process group;
- `workingDirectory` returns the real path (`/private/var` on macOS);
- a spawned child has no descriptor above 2 (listed from inside it through `/dev/fd` or `/proc/self/fd`);
- `parent` of an orphaned process is whatever adopted it (PID 1 or the subreaper), and the sweeper still finds it.

Fixture tests for the `/proc/<pid>/stat` parser run on both operating systems.

## Acceptance

- [ ] `swift build` and the full suite pass on macOS and on Linux, in CI, on every PR.
- [ ] The Linux job also runs the lifecycle tests: a hang, a child that ignores SIGTERM, an escaped grandchild, a
      crash and its recovery, and a descriptor leak check; the soak passes on Linux.
- [ ] The Linux suite passes as a non-root user (the permission test is not skipped).
- [ ] No `#if` outside `Platform*.swift`, `CShim` and the import lines; `scripts/check-banned-apis.sh` still passes
      and also covers the Linux files.
- [ ] A process orphaned under a subreaper is found and ended by the sweeper.
- [ ] The ready check returns within its deadline with the resolver unreachable.
- [ ] Docs that name macOS 14+ (README, AGENTS.md) say what is supported on Linux.

## Out of scope

- Windows.
- Linux versions of anything with no CLI behaviour (`open` in an editor, desktop notifications): they degrade with a
  clear message instead of being ported.
- A pidfd-based exit watcher (`pidfd_open` plus a read source) is an optimisation behind `ExitNotifying`, later.
- Packaging and distribution of a Linux binary.

## Decisions to make

- **Runner:** GitHub-hosted `ubuntu-latest` in a `swift` container versus a self-hosted one. The probe's timing against
  the macOS job decides it.
- **Whether Linux replaces or joins macOS** for the soak. Joins is the default; macOS stays the supported desktop.
- **Subreaper at startup:** on by default on Linux, or only for long-running commands. Default on unless a test shows
  it changes exit-code behaviour.
