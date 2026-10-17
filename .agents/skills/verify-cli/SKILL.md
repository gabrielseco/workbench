---
name: verify-cli
description: Check a just-merged Workbench feature by using it for real — build `.build/debug/workbench` and run one scenario script that drives a throwaway thread on this repository with the real `claude`, using only workbench commands, and reports PASS or FAIL per step. Use after a CLI feature merges ("verify abandon for real", "run the verify-cli scenario for <feature>"), or when adding the scenario for a new feature. Costs money; run by hand, never in CI.
---

# verify-cli

There is no UI yet, so a merged feature is checked the way a person would use it: Workbench runs on this
repository, with the real `claude` (never `fake-claude`), and the scenario uses workbench commands for the
whole thread. Unit tests and the soak prove the code with a test double; this proves the binary, the config
and the real CLI together, once, after the merge.

Each feature has one script, `scripts/verify-cli/<feature>.sh`. Today there is `abandon` (P12 task 1).

## When to use it

- After a pull request that changes what a workbench command does has merged, and `main` is checked out.
- Not for a target project's change (that is `verify_command`, P4 and P11), and not in CI.

## Running one

```bash
git checkout main && git pull --ff-only            # the main checkout, clean, at origin's main
bash scripts/verify-cli/abandon.sh                 # VERIFY_CLI_BUDGET_USD=0.50 VERIFY_CLI_MODEL=haiku by default
VERIFY_CLI_SABOTAGE=1 bash scripts/verify-cli/abandon.sh   # breaks abandon's output on purpose: must FAIL
```

It refuses (exit 2) and changes nothing in the repository, its threads or branches when: it is not run in
the main checkout, the checkout has local changes, `HEAD` or `origin/main` is not origin's `main`, a thread
is active here (one project, one active thread; end it with `abandon` or `discard` first), or
`claude_path` resolves to nothing or to `fake-claude`. The only thing it does before refusing on those last
two is `swift build --product workbench`, since the checks use the fresh binary.

## What a run costs

One real turn, capped by the goal's `budget_usd`: `VERIFY_CLI_BUDGET_USD` (default 0.50 USD) on the cheap
model (`VERIFY_CLI_MODEL`, default `haiku`). A goal that did not take the cap is abandoned before any turn.
The abandon scenario's turn writes one small file and commits it; expect a few cents and one to three
minutes, plus the build. The summary prints what the turn cost, read from the thread's `turn.ended`.

## Reading the report

- `$ workbench …` lines are the commands, as they run, and again under `commands run:` at the end.
- One `PASS  <step>` or `FAIL  <step>: <why>` line per step; indented lines under a step are its evidence.
- `cost of the real turn:` from the thread's log, with the cap and model.
- `RESULT: PASS (n steps)` and exit 0 only when every step passed. `RESULT: FAIL (k of n): <steps>` and exit 1
  otherwise. Exit 2 is a refusal before anything ran; 130 an interrupt (it says what was left).
- On a pass the throwaway branch, the restore checkouts and the temp folder are removed; on a fail they are
  kept and named, with the commands to remove them. The thread's log always stays: an abandoned thread is a
  record (`workbench status --all` shows it).

A FAIL is a finding about the merged feature (or about the scenario): read the kept branch, checkouts and
`workbench log <id>` before changing anything, and say which in the report.

### abandon (P12 task 1)

`goal new` (from a throwaway goal: add `scratch/verify-cli.txt`), `goal approve`, `run`, then the script
leaves the worktree with a modified tracked file (`README.md`), a file staged and edited again, a staged file
deleted from disk, an untracked file and a binary file, and runs `abandon` without `--force`. Steps: the goal
approved with the cap; the turn succeeded; the log has real `claude` stream lines (the `turn.started` argv
and the `system/init` line); abandon exit 0; worktree gone; branch kept; `abandon.patch` and
`abandon-staged.patch` exist; `abandon.saved` in `workbench log` with size, sha256, tree and head (and they
match the file); `git apply` of each patch on a fresh checkout of the branch tip restores the files; no
process of the worktree is left.

## Adding a scenario for the next feature

One task, one script: `scripts/verify-cli/<feature>.sh`, started with `bash`. Copy `abandon.sh` and keep its
frame, which is what makes a run safe to repeat:

1. **Refuse first, change nothing**: main checkout, clean, at origin's `main`, no active thread, the real
   `claude`.
2. **Every command bounded**: `with_timeout` (workbench through `wb`, git through `g`); a turn's goal gets
   the `VERIFY_CLI_BUDGET_USD` cap, the cheap model and a short `turn_timeout_min`, checked after approval.
3. **Workbench commands only for the thread**; plain git or files only to set up the state the feature acts on.
   Read results through `--json` (`status`, `review`, `log`), not by parsing text.
4. **One `check "<step>" "<why>" <command>` per thing the plan says the feature does**, so the report reads as
   the task's criteria.
5. **A sabotage switch** (`VERIFY_CLI_SABOTAGE=1`) that breaks the feature's output after it ran, so a run
   shows the assertions can fail.
6. **Tidy on pass, keep on fail**: remove the branch and checkouts it made only when everything passed, end
   every thread it started, leave no process in the worktree, print the cost.

Then add a `### <feature>` section above listing its steps, and put the hand run's output in the PR.
