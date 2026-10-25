# P17: Faster tests

Status: plan; task 1 (profile) built. Written 2026-10-24. Complements [P8](P8-faster-checks.md), which is about the
check a *thread* runs; this is about the repo's own `swift test`. Builds on the `ci-test-timings` branch
(`scripts/test-timings.py`, `scripts/ci-report.sh`), the `ProcessGate` (#161, #169) and `Patience`.

## Why

The suite is the slowest step of every PR and of every local loop. Measured 2026-10-24 on an 11-core Mac,
1360 tests in 179 suites:

| Run | Wall time |
|---|---|
| `swift build --build-tests` (incremental) | 26 s |
| `swift test` (parallel) | 178 s |
| `swift test --no-parallel` | 955 s |

## What was measured

Numbers come from `swift test --no-parallel`, because in a parallel run every test's reported time includes
its wait for a `ProcessGate` permit (in the parallel log 676 of 1298 tests read over 60 s and the slowest
suites all read 165 to 177 s, the length of the run). Only the serial run gives a cost per test.

1. **A small share of the tests holds most of the time.** Median test 0.17 s; 777 of 1357 take 0.3 s or
   less. 298 take over 1 s and hold 79% of the 954 s summed test time. p90 is 2.1 s, p95 2.6 s. (An earlier
   figure of 90% counted the `Test run with …` summary line as a test.)
2. **The slow ones wait on git, one process after another** (task 1 probe, warm, serial). A fixture is only
   0.05 s, a `workbench status` spawn 0.06 s and a fake-claude turn 0.19 to 0.25 s. But `workbench accept`
   takes 1.0 s: `acceptPlan` alone spawns 17 `git` processes in a row at about 11 ms each (0.19 s), and the
   command runs it twice. Several calls repeat (`rev-parse refs/heads/workbench/<id>` twice, `diff --numstat`
   and `--name-status` twice, `ls-files --others` twice). That is the idle half of the CPU time and most of
   the system time (`posix_spawn`). A bigger fixture saving would come from fewer or parallel git calls in the
   product, not from a cheaper fixture. Cold first runs are slower (fake turn 0.6 s, first CLI spawn 0.45 s).
3. **Parallelism is capped well below the machine.** `ProcessGate` permits one process-spawning test per core;
   the parallel run used 281% of 1100% CPU. The gate exists for a 3-core CI runner where hundreds of tests
   starved each other, so the right size differs between CI and a laptop.
4. **A few tests wait on purpose.** `aStoppedLauncherTakesWhatItStartedInANewSessionWithIt` waits a fixed 20 s
   timeout; `anAnswerWithoutAVerdictLineIsAFailureNeverAPass` 10 s; `aHangingCodexIsEndedAtTheTimeout…` 9.7 s;
   several Doctor and review-loop tests 6 to 11 s. 23 test files use real sleeps or timeouts.
5. **Fixtures leak.** `$TMPDIR` held 4647 `wb-*` directories (1.1 GB) after a few runs.
6. **No result cache.** Only the manual `--filter` rule (AGENTS.md, `check-changed.sh`) limits what runs.

## Goal

| Measure | Now | Target |
|---|---|---|
| Full `swift test`, 11 cores | 178 s | 60 s or less |
| Full `swift test`, CI (3 cores) | run the Test profile job once | no slower than now, then at least 30% faster |
| `check-changed.sh` on a typical diff | measure in task 8 | 15 s or less |
| `workbench accept` (CLI, warm) | 1.0 s | 0.4 s or less |
| `--no-parallel` total | 955 s | 400 s or less |
| Leftover `wb-*` dirs after a run | thousands | 0 |

Targets are confirmed against task 1's baseline; a target missed is reported, not hidden.

## Rules for every task

- One PR per task, Conventional Commits, `scripts/check-changed.sh`, Codex review (AGENTS.md).
- **No weaker test.** A test keeps asserting what it asserted; only its fixture, timeout or process count
  changes. A test that cannot be made faster without losing its point stays and is named in the list at the
  end of this file.
- **Reliability first.** The timeout, SIGTERM-ignoring, crash and leftover-process tests are acceptance
  criteria of the product (AGENTS.md). Shorter timeouts still use `Patience.limit` as the hang ceiling.
- Before and after numbers in each PR: the same two commands as the table above.
- No `workbench` command changes, so no verify-cli scenario; say so in each PR.

## Tasks

### 1. Profile (built)

- `scripts/test-profile.sh [out-dir]`: a serial `swift test`, then `scripts/test-timings.py --serial`; writes
  `test.log`, `timings.json` and `timings.md` and prints the slowest suites and tests.
- `test-timings.py`: no longer counts the `Test run with …` line as a test; prints how many tests take over 1 s
  and the share of time they hold; says in a parallel log that its times include gate waits.
- `.github/workflows/test-profile.yml`: manual job that runs the profile on the CI runner. **Run it once and
  record the 3-core baseline here** before tasks 3 and 7.
- Phase timings of a fixture, a turn, a CLI spawn and `accept` were measured with a throwaway test (not kept);
  the result is finding 2.

Done when: finding 2 has a cause (it does: sequential git spawns) and the CI baseline is recorded (open: run the `Test profile` workflow once it is on `main`, then fill in the goals table).

### 2. Clean up temp directories (built)

- `Scratch` (Tests) owns one root per test process, `$TMPDIR/wb-scratch-<pid>-<uuid>`, removed at exit
  (`atexit`). `Scratch.url(prefix)` replaces the 46 places that made their own `$TMPDIR/<prefix>-<uuid>`.
- `RunnerFixture` puts its repo in `<root>/run-<uuid>/repo`, so the fakes tests put beside it (`gh-*`,
  `codex-*`, `origin-*`, `judge-*`, `plan-*`; thousands each) are inside the run's directory and go with it.
- The first use sweeps roots whose pid no longer runs (a killed run) and `wb-*` directories older than a day.
- Measured: a full parallel run (1468 tests) leaves no scratch root, and `$TMPDIR` grew by 18 entries from
  other processes instead of thousands. `ScratchTests` covers the path, the dead and live roots and the
  age rule (directories only; a `wb-*` file is never removed). `scripts/check-test-leftovers.sh` runs after the
  tests in `check.sh` and CI and fails on a scratch root whose process is gone, so a test that bypasses `Scratch`'s
  exit cleanup shows up. A run killed with SIGKILL still leaves its root until the next run's sweep.

Done when: a full run leaves no `wb-*` directory (done).

### 3. Size the gate by measurement (done: the gate is not the limit)

- `WORKBENCH_TEST_PERMITS` overrides `ProcessGate.shared`'s size (a positive number; anything else is ignored);
  the default stays one per core with a floor of two. `ProcessGate.permits(environment:cores:)` is tested.
- Measured 2026-10-24, 11 cores, full parallel run of 1468 tests, **load average 17 from other work on the
  machine** (so absolute times are noisy):

  | Permits | Wall time | Result |
  |---:|---:|---|
  | 11 (1x cores, the default) | 181 s | all pass |
  | 22 | 170 s | 2 flaky failures (the editor hang test took 143 s, a check CLI test 146 s) |
  | 33 | 176 s | passes |
  | 44 | 191 s | the editor hang test took 163 s |

- Conclusion: more permits do not make the run faster and make the timeout tests flaky, so the default stays.
  The earlier reading (281% CPU of 1100%) does not mean the gate is too small. What limits the parallel run is
  still unknown; candidates are the cooperative thread pool (as wide as the core count, and a test that blocks a
  thread holds it), the longest chains of tests in one suite, and the git spawns of finding 2. Measure on a quiet
  machine and by the CI baseline (task 1) before spending more here.

Done when: the question "is the gate too small?" is answered (it is not).

### 4. Fewer and parallel git calls in the commands the tests drive (built)

Replaces "share the fixture": a fixture costs 0.05 s, so a template saves little (finding 2).

- Count the git processes of the commands the slow suites run (`accept`, `review`, `ship`, `status`) with
  `GIT_TRACE2_EVENT`, and list them in the PR.
- Remove repeats (the same `rev-parse`, `diff --numstat`/`--name-status` and `ls-files --others` run twice in
  one `acceptPlan`), pass a result along instead of asking git again, and run independent calls together
  (`async let`) with the existing bounds on children.
- Behaviour, output and exit codes stay the same, so no verify-cli scenario; the existing tests are the proof,
  plus one test per changed function that counts spawns (a fake `GitRunner` records its calls).

Done when: `acceptPlan` spawns 10 or fewer git processes (from 17) and the CLI `accept` takes 0.4 s or less.

Built for `acceptPlan` (2026-10-25). It spawned 17: `symbolic-ref`, `status`, `log` for the commits, then
`ReviewLoader.load` (`rev-parse` of the branch twice, `rev-list --count`, `log`, and the plain diff: two `diff`
and `ls-files --others`), then a second, full `DiffProvider.summary` that repeated the same three and added the
staged and ignored reads. Now:

- `acceptPlan` uses only the diff of the review report, so it no longer loads the report's branch lookups (4).
- `DiffProvider.summary` is read once with staged and ignored files, and the list `review` shows is
  `DiffSummary.plain()` of it (3 fewer; `FileChange.isIgnored` marks what is only there for discard).
- The independent reads run together (`async let`): `symbolic-ref`, `status`, `log` and the diff in one round, and
  the up to seven reads inside `summary` in another. The answers are still checked in the old order, so the
  refusal a person sees is the same. `GIT_OPTIONAL_LOCKS=0` keeps them off the index lock.
- Result: 10 git processes (from 17), `acceptPlan` 0.43 to 0.57 s against 0.86 s through a counting wrapper, and
  `AcceptTests` 23.3 s to 12.6 s serial. `AcceptGitCallsTests` pins it: no git command runs twice, and at most 10.

### 5. Shorten the waits that are by design

- Make each timeout and grace a parameter the test chooses (`EditorLauncher.launch(timeout:killGrace:)`
  already is). The 20 s editor test uses the shortest timeout that outlasts `python3` starting, with the
  helper's pid file as the signal.
- Same for the 10 s verdict-line test, the hanging Codex test, and the Doctor-boundary and review-loop tests,
  one test at a time, checked over 20 runs with all cores busy.
- `Patience.limit` stays 60 s as the ceiling; a short timeout is the thing under test, not a measurement.

Done when: no single test takes over 5 s, except the ones named at the end of this file.

### 6. Fewer processes per test

- Where a test checks logic, call `ThreadService` (or the command's type) in-process instead of spawning the
  `workbench` binary. Keep one real-CLI test per command for its output, flags and exit code.
- Start with `AcceptTests`, `Ship*Tests`, `Review*Tests` (largest suites); list each conversion in the PR.
- Never convert a test whose point is process behaviour (signals, exit codes, process groups, leftovers).

Done when: spawns of `WorkbenchBinary.executable` are down by at least a third, and the PR names the real-CLI
test that still covers each command.

### 7. CI

- Apply the measured permits to CI (task 3); compare 3 consecutive runs before and after.
- Cache `.build` keyed on `Package.resolved` and the Swift version, if the build step is a large part of the
  run (read it from the timings artifact first).
- Keep the soak as its own step.

Done when: the CI test step is at least 30% faster, or the PR says what stopped it.

### 8. Make the local loop fast

- `scripts/check-changed.sh` is already in AGENTS.md; add its measured typical time to the doc.
- Optional: a result cache for it, keyed on the hash of the suite's sources, its test files and
  `Package.swift`; a hit prints `(cached)`. Only if tasks 1 to 7 leave a typical run over 15 s.

Done when: a typical diff checks in 15 s or less, or the remaining cost is explained.

## Order

1 first (everything is guided by it), then 2 (independent, small), then 3 and 4 (can run in parallel; 4 touches
product code, not tests), then 5 and 6 (independent of each other), then 7, then 8. Task 4 is the one with the
most to gain: each git process saved is saved in every test that runs the command.

## Risks

- **Starvation returns.** Tasks 3, 4 and 7 can bring back what `ProcessGate` fixed (#161). CI keeps its
  current permits until a 3-core measurement says otherwise; 3 CI runs before each merge.
- **Parallel git calls race.** Two git commands on one worktree can contend for `index.lock`. Run in parallel
  only read-only commands that do not refresh the index, and test the sequence under load.
- **Shorter timeouts flake under load.** Run under full load before merge; a flake is a revert, not a longer
  timeout.
- **In-process tests miss CLI wiring.** One real-CLI test per command stays (task 6).

## Not in this phase

- Test result caching across machines.
- Splitting `WorkbenchCore` into several targets to cut compile time.
- Changing the product's own timeouts or grace periods; only tests choose shorter ones.
- Anything about the cost of a Workbench run (P8).

## Tests that stay slow (fill in during task 5)

| Test | Time | Why it cannot be shorter |
|---|---|---|
| | | |
