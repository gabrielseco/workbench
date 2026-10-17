# P8: Faster checks inside a thread

Status: plan; task 1 (measure) built, see "Measured". Written 2026-10-17. Friction row 49. Follows [P2.6](P2.6-harden.md) (the check after
each turn) and the diff-scoped `scripts/check-changed.sh` (#86).

## What was measured

P6 task 2 (`g-2026-10-17-p6-review-stage-command`), one turn of 1022 s and $4.03, `check_command =
scripts/check-changed.sh` was not yet set (the thread was allowed to run it by hand):

- `scripts/check-changed.sh` was started **three times** by Claude inside the turn (05:01, 05:05, 05:08). The two
  runs whose end is in the log took about **2 m 20 s** each, so roughly 7 of the 17 minutes of the turn were spent
  waiting for the check.
- Workbench then runs `check_command` itself after the turn: a **fourth** run of the same kind.
- A similar diff-scoped run in a warm worktree earlier the same day took 36 s for 332 tests, so the 2 m 20 s is not
  the floor.
- 5 tool calls were denied, among them a plain `swift test` and `python3`; Claude fell back to
  `scripts/check-changed.sh` and the `Edit` tool, which worked.

Times are read from the event log's timestamps. The causes below were not measured.

## Likely causes (to confirm first)

1. **The "narrow" check is not narrow for core types.** A changed source file maps to suites by file name, and when
   none match, by grepping the tests for the type name. A change to a type used everywhere (`GitRunner`, the event
   log, `Config`) matched 35 suites in one earlier run; this turn changed the event log and config files.
2. **A few suites are slow by design.** The Codex-runner suites and the ship-preflight suite include tests that wait
   out a timeout (15 s and more each).
3. **The same check runs more than once.** Claude runs it to get feedback, and Workbench runs it again at the end.
4. **A cold first build** in a fresh worktree is part of the first run.

## Measured (task 1, 2026-10-17, 11 cores, load average 17 from other work)

`check-changed.sh` now prints each step's time and the suite count. Runs on this repo, base `HEAD`:

| Change | Suites | Build | Tests | Total |
|---|---|---|---|---|
| `Config.swift` (cold edit, incremental compile) | 6 | 25 s | 1 s | 27 s |
| `Config.swift` (warm) | 6 | 1 s | 2 s | 4 s |
| 7 files under `EventLog/` and `Git/` | 58 of ~60 | warm | 63 to 87 s | 63 to 87 s |

- **Cause 1 holds, for the wide types.** Seven files in two core folders select 58 suites, nearly the whole
  project. Config selects 6. The cap in task 2 is the right fix.
- **Cause 2 does not.** Each of the slow-looking suites runs alone in 4 to 8 s (`ShipPreflightTests` 6 s,
  `ReviewStageRunnerTests` 3 s, `ShipOpenPRTests` 5 s, `PRReviewTests` 7 s). In the wide run the same tests report
  80 s because every test starts at once and waits for CPU, so per-test times there say nothing. Serial
  (`--no-parallel`) is 400 s, so parallelism already earns a lot.
- **The wide run is CPU and process-spawn bound:** 65 s user, 117 s system, 286% CPU, with the machine already
  loaded. Suite count, not any one slow test, is the cost.
- **Cause 4 is small:** an edit's incremental compile was 25 s once; with nothing to rebuild it is 1 s.
- Cause 3 (the same check run several times) is multiplied by all of the above: at 60 to 90 s a wide run, four
  runs in a turn is the 7 minutes seen. Tasks 3 and 4 stand.

## What to build

1. **Measure first (S).** Make `check-changed.sh` print its timing per step and the number of suites chosen, (Workbench
   already records the whole check's `duration_ms` on `check.ran`, so nothing changes there). One real turn's log then says
   which of the causes above holds. No behaviour change.
2. **A tighter mapping (S).** Name match first; the type-name grep only when a source file has no name match, and
   never for a file under `Sources/WorkbenchCore/{Git,EventLog,Config,Process}` (widely used): those map to their
   own named suites. When more than a set number of suites (default 15) would run, print which files caused it and
   run the named ones plus a full `swift build --build-tests`, leaving the wide run to CI. `--quick` runs lint and
   only the name-matched suites.
3. **Say it in the goal (S).** The goal template's last criterion reads "the changed files lint clean and their
   suites pass (`scripts/check-changed.sh`, run once at the end)", and the first prompt tells Claude to use
   `swift test --filter` on the suites it touched while working. The allowlist already permits both.
4. **One authoritative check (S).** Decide whether Claude's last run and Workbench's post-turn run are both needed.
   Workbench's run is the recorded one, so the proposal is: Claude may run the narrow filter freely, but treats
   `check-changed.sh` as Workbench's job unless it has changed something after the last run. Needs a prompt change
   and a look at how often a failing post-turn check then costs a whole `send-back`.

## Tests

- The mapping: a core type's change picks its named suite only; the cap prints the files that caused it; a project
  with few suites is unchanged. Extend `CheckChangedTests` (it already runs `--plan` in a throwaway repo).
- The timing line and suite count appear in the output; `check.ran` data is unchanged.

## A flaky test the checks keep hitting

`ShipPreflightTests.aHungOriginEndsInATimeoutAndLeavesNoProcess` failed in the post-turn check of both P6 task 1 and
P6 task 2 ("`git remote` / `git symbolic-ref` did not finish in 3s" where the test expects the `ls-remote` timeout)
and passed on its own both times (17 of 17 in about 6 s). Under the load of a full run, the 3-second limit is hit by
an earlier git step. Fix it in the test (a longer limit for the steps before the one under test, or fake only that
step), because it turns a good thread's check into "failed" and the person has to rerun it by hand.

## Related, not part of this plan

The same run showed which commands a thread is denied. Only narrow, in-repo commands belong in a default
allowlist: read-only git (`git log`, `git show`, `git ls-files`) and `git mv` are safe to add. Interpreters
(`python3`, `sh`, `node`, `perl`) and `curl` are not: a script escapes the worktree and the denylist, which only
sees the command string. A project that trusts its own repo can opt in by hand. Decision for `wb init`'s template and
this project's config: add the read-only git set and `git mv`, nothing else.

## Open questions

- **Default suite cap:** 15, or a share of the project's suites?
- **Who runs the check:** is it acceptable that Claude does not run `check-changed.sh` itself on a first pass, at the
  cost of one more `send-back` when the post-turn check fails?
- **Parallelism:** whether `swift test --parallel` or the Swift Testing default already uses every core on the
  machine, which would make suite count matter less than the slow tests.
