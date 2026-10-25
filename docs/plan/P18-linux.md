# P18: Linux

Status: plan, nothing built. Written 2026-10-25. Starts from the throwaway probe in PR #221 (`probe/linux-build`),
which ports the package to Linux in one 40-file diff and is not for merge. This phase ships the same result as
small PRs and keeps Linux green afterwards. Complements [P17](P17-faster-tests.md) (the Linux job must not slow the
gate) and [`../later/portability.md`](../later/portability.md) (other stacks, not other operating systems).

## Why

**The goal is CI velocity with more PRs open at once.** GitHub caps concurrent macOS jobs far below Linux ones
(#219 moved lint to Linux for that reason), so every PR that holds a macOS slot for the whole suite queues the next.
Linux is the way to run many PRs in parallel. A Linux port that is correct but slower than macOS fails that goal, so
speed is an acceptance criterion here, not a nice-to-have. Secondary gains: the soak and leftover checks run on a
second kernel, and Workbench can run on a server.

The probe shows the code needs few changes; what is missing is a way to keep two platforms correct without `#if`
spread through the code, and a Linux job that is not the slowest check.

## Speed

Measured on the #221 probe (2026-10-25, `ubuntu-latest` in a `swift:6.2.1` container, `--init`): macOS `build-test`
7 m 55 s for the whole job; Linux build about 1 m, and the Linux `swift test` still running after 13 m. So the first
Linux run is slower than macOS, and the reason is not yet known. Suspects: fewer cores than the 11-core Macs P17
measured (the `ProcessGate` is sized by cores and the suite is spawn-heavy); the missing kqueue exit event, so each
test that waits for a child pays the poll interval; a few outlier tests. Task 0 measures before anything else is
built.

What Linux allows that macOS does not is **sharding**: Linux slots are plentiful, so one PR can use several jobs.
Each job builds (about 1 m, cached) and runs a disjoint set of suites; PR wall time is the slowest shard.

The soak (79 s on the macOS runner, its own step) cannot become a separate job on macOS, because that holds a second
macOS slot per PR; on Linux it is a parallel job of its own, so it leaves the critical path. That is one reason the
gate moves to Linux and not just a second macOS job.

CI baseline on `main` (2026-10-25, after P17 tasks 4 and 5): build 39 s, test 451 s, soak 79 s, 9m42s in all. P17 found
the remaining suite cost is the work the tests do (a serial run is 907 s; the CI test step runs about 2x faster than
serial), so per-test tuning is largely spent and sharding is the lever that scales.

## What the probe changed (and what that tells us)

| Area | macOS only | Linux replacement |
|---|---|---|
| Hashing | `CryptoKit` (6 files) | first `swift-crypto` (task 1), then our own plain-Swift SHA-256 (task 1b), the only hash used |
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

`ProcessMember` keeps `pid`, `startSeconds` and `startMicros` as they are written to `runner.json`: the platform fills them (on Linux clock ticks and 0), and callers only compare or order them. (Task 2 first planned one opaque `start` token; that would have changed the file format and about 17 test files for no gain.) Pure parsing (`/proc/<pid>/stat` fields, which may hold
spaces and parentheses in the command name) is a plain function so macOS CI can test it with fixtures.

**Orphans.** An orphan is a process whose working directory is inside the worktree and whose parent is one of the
platform's *adopters*: PID 1, and on Linux whichever ancestor adopts orphans of this process tree (`systemd --user`, a
supervisor, a container's init; found once per process by orphaning a throwaway `sleep` and reading its new parent).
Everything running beneath an orphan is swept too. The first draft of this section said "any process in the worktree
that is not a descendant of a live Workbench process"; that would kill a shell the user has open in the worktree under
tmux or ssh, whose parent is live and ordinary, so it was not used. `becomeSubreaper()` is not called at startup: a
subreaper would adopt its own orphans as zombies it has to reap, and the adopter probe makes it unnecessary.

**Ready check.** A `LoopbackProbe` accepts only `127.0.0.1`, `::1` and `localhost` (mapped to both literals), parses
them with `inet_pton` after stripping the brackets of an IPv6 URL host, connects non-blocking and waits only through
`poll` against one deadline. No `getaddrinfo`.

## Tasks (one PR each)

| # | PR | Notes |
|---|---|---|
| 0 | **Measure the probe**: per-suite and per-test Linux time against macOS from `scripts/ci-report.sh 221`, cores on both, and the poll interval's share | No code. Output is a table in this file and a target: the Linux PR gate finishes no later than the macOS job did. |
| 1 | **Portable libraries**: `swift-crypto` for the six `CryptoKit` imports (replaced in task 1b by our own `SHA256`, see below), system zlib for `Gzip` (`CZlib`) | Behaviour identical on macOS; the existing hash and gzip tests are the proof. `zcat` and `gzip -t` must still read what is written. |
| 2 | **Platform contract, macOS only**: the four protocols, `Platform+Darwin.swift` (today's libproc code moved, not changed), `ProcessMember` with an opaque start token, `Spawner`, `ProcessTree` and `OrphanSweeper` call through it | Refactor, no behaviour change. Adds the contract tests (below), run on the current platform. |
| 3 | **Linux implementation**: `Platform+Linux.swift`, `CShim`, the `stat`/`siginfo_t` accessors, `Glibc` imports, fake-claude and test fixes, a Linux build job | Builds and passes the whole suite in a `swift:6.2` container with `--init`. |
| 4 | **Orphan ownership**: an orphan's parent is one of the platform's adopters (`orphanAdopters`), not just PID 1 | Rule tests on a described machine (an adopted process, one under a subreaper, a shell under tmux left alone, a reused pid); a real orphan's parent is one of the platform's adopters; the two Linux-disabled tests run again. |
| 5 | **Loopback ready check**: `LoopbackProbe` replaces `Network.framework` | Tests: response split across packets, early close, timeout, cancel, IPv6 literal, a name that does not resolve. |
| 6 | **Linux becomes the PR gate, macOS moves off it**: the suite is sharded across parallel Linux jobs (each a disjoint set of suites, together all of them), with the soak, the leftover-process checks and one non-root run; macOS keeps a smaller job on `main` and nightly (and on PRs that touch `canImport(Darwin)` files) | Target: PR wall time at or below today's macOS job, and a PR holds no macOS slot unless it touches Darwin code. Decide shard count and runner size from task 0. |

Task 0 can start now and decides how task 6 is shaped. Tasks 1 and 2 are independent of each other and of Linux. 3 needs 1 and 2. 4 and 5 can follow 3 in either order;
6 comes last but may start as soon as 3 lands, with the soak added when 4 is in.

## Measured (2026-10-25)

Task 0, on the probe merged with `main` (4-core GitHub runner, 1712 tests, 16 permits unless noted):

| Gate permits | Wall | CPU busy | Result |
|---:|---:|---:|---|
| 4 (the default: one per core) | 540 s | 8.9% | 10 failing tests |
| 16 | 341 s | 16.3% | the same 10 |
| 32 | 368 s | 18.6% | the same 10, no faster than 16 |
| 64 | crashed after 64 s | | libdispatch segfault in `_dispatch_event_loop_drain` |

- Linux spends its time waiting, not computing: a process costs about 2 ms of system time (10 ms on macOS), the CPU is
  more than 80% idle at 16 permits, and the default of one permit per core leaves it 91% idle. 16 permits is the setting.
- The 10 failures were: the container running as root (5, fixed by an ordinary user), `BaseGapTests` (3, a relative
  `FETCH_HEAD` path that a standardized `URL` loses its base on Linux, fixed in product code), and two orphan tests
  (an orphan is adopted by a subreaper, not always PID 1: task 4; they are disabled on Linux until then).

Task 3 (the Linux platform, this branch), same runner, two parallel jobs (tests, soak) in separate containers:

| | Build | Run | Result |
|---|---:|---:|---|
| `test` | 104 to 235 s | 121 to 174 s | 1720 tests pass |
| `soak` | 119 to 143 s | 185 to 193 s | passes (it failed once when run after the tests in the same container: a leftover `sleep 300` from another suite) |

- A whole run is about 6 to 6.5 minutes (the two jobs overlap), against 8m41s for macOS.
- The build is the slow part on Linux: a cold build takes 146 to 256 s (about 35 s for the dependencies, the rest our
  own Swift) and varies a lot by runner. Task 1b removed `swift-crypto` (only SHA-256 was used, and it compiled
  BoringSSL on the critical path) for a plain-Swift `SHA256` held to the FIPS vectors and, on macOS, to CryptoKit.
- Build cache, measured with a throwaway workflow (3 runs each): a restored `.build` alone helps little (warm builds of
  137 to 150 s), because a fresh checkout gives every source file a new modification time and SwiftPM rebuilds what
  looks newer. With each file's time set to its last commit time (`git log --name-only`, full history) the same cache
  gives a warm build of **3 to 5 s with nothing changed and 24, 27 and 37 s after changing one source file and one
  test file**. Done: `.github/actions/linux-build` (shared by the `test` and `soak` jobs) restores `.build` from the
  newest earlier build of the same Swift version and `Package.swift`, restores the file times, builds, and the `test`
  job saves `.build` right after the build; pushes to main fill the cache that pull requests start from. Not measured:
  a change to a widely used file, a `Package.swift` change (cold again), and a cache evicted after 7 days.
- Open: an intermittent segfault inside libdispatch's event loop on Linux (the same signature as the 64-permit crash),
  seen in 1 of 5 full runs at 16 permits. It has to be understood before Linux is the gate.

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

- [ ] The Linux PR gate is no slower than the macOS job it replaces, and three PRs open at once do not queue behind
      each other on a macOS slot.
- [ ] `swift build` and the full suite pass on Linux on every PR and on macOS on `main` and nightly (and on PRs
      that touch Darwin files).
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

- **Runner and shard count:** hosted `ubuntu-latest` in a `swift` container (how many shards) versus a larger or
  self-hosted runner. Task 0's timing decides it.
- **What stays on macOS per PR:** nothing, or only PRs touching Darwin files. macOS stays the supported desktop and
  is tested on `main` and nightly either way.
- **Subreaper at startup:** on by default on Linux, or only for long-running commands. Default on unless a test shows
  it changes exit-code behaviour.
