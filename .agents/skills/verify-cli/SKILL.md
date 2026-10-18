---
name: verify-cli
description: Check a Workbench feature by using it for real — build `.build/debug/workbench` and run one scenario script that drives a throwaway thread on this repository with the real `claude`, using only workbench commands, and reports PASS or FAIL per step. Use with every change to what a workbench command does, from its branch before the PR is ready ("verify abandon for real", "run the verify-cli scenario for <feature>"), or when adding the scenario for a new feature. Real-turn scenarios cost money; run by hand, never in CI.
---

# verify-cli

There is no UI yet, so a feature is checked the way a person would use it: Workbench runs on this
repository, with the real `claude` (never `fake-claude`), and the scenario uses workbench commands for the
whole thread. Unit tests and the soak prove the code with a test double; this proves the binary, the config
and the real CLI together, once per change, from its branch.

Each feature has one script, `scripts/verify-cli/<feature>.sh`. Today there are `abandon` (P12 task 1), `grant` (P13 task 7), `plan` (P14 task 5) and `doctor` (P15 task 1) `help` (P15 task 2) and `criteria-tests` (P15 task 3).

## When to use it

- With every change to what a workbench command does (`AGENTS.md`, "Shipping a change", step 3): add or update the
  scenario in the same PR and run it from the branch, normally and with `VERIFY_CLI_SABOTAGE=1`. It can also be run
  on `main` after the merge.
- Not for a target project's change (that is `verify_command`, P4 and P11), and not in CI.

## Running one

```bash
git checkout main && git pull --ff-only            # the main checkout, clean, at origin's main
bash scripts/verify-cli/abandon.sh                 # VERIFY_CLI_BUDGET_USD=0.50 VERIFY_CLI_MODEL=haiku by default
bash scripts/verify-cli/grant.sh                   # two turns (the second is a send-back), each capped at the budget
bash scripts/verify-cli/plan.sh                    # one plan turn and one coding turn, each capped at the budget
bash scripts/verify-cli/help.sh                    # no turn, costs nothing
bash scripts/verify-cli/criteria-tests.sh          # a test: proof backed by the check (one tiny turn, then the suite runs)
bash scripts/verify-cli/doctor.sh                  # doctor after approve and during a live turn (stopped early, a few cents)
VERIFY_CLI_SABOTAGE=1 bash scripts/verify-cli/abandon.sh   # breaks abandon's output on purpose: must FAIL
VERIFY_CLI_SABOTAGE=cleanup bash scripts/verify-cli/abandon.sh   # a cleanup step fails on purpose: must FAIL, exit 1
```

The shared frame (refusals, timeouts, the tally, the cost, the cleanup) is `scripts/verify-cli/lib.sh`; each
`<feature>.sh` sources it.

Before the pull request merges, run it from the branch: accept the thread, `git checkout workbench/<id>` in the main
checkout (clean, no active thread) and set `VERIFY_CLI_FROM_BRANCH=1`. `HEAD` then only has to contain origin's
`main`; the binary it builds and checks is the branch's. Go back with `git checkout main`.

It refuses (exit 2) and changes nothing in the repository, its threads or branches when: it is not run in
the main checkout, the checkout has local changes, `HEAD` is not origin's `main` (with `VERIFY_CLI_FROM_BRANCH=1`: does not contain it), `origin/main` is not origin's `main`, a thread
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
- On a pass the throwaway branch and the restore checkouts are removed, each as a `cleanup:` step, then the
  temp folder. On a fail, including a cleanup step that failed, the rest and the temp folder are kept and
  named, with the commands to remove them. The thread's log always stays: an abandoned thread is a
  record (`workbench status --all` shows it).

A FAIL is a finding about the merged feature (or about the scenario): read the kept branch, checkouts and
`workbench log <id>` before changing anything, and say which in the report.

### abandon (P12 task 1)

`goal new` (from a throwaway goal: add `scratch/verify-cli.txt`), `goal approve`, `run`, then the script
commits `scratch/verify-cli.txt` on the thread's branch itself (writing it if the model did not) and checks
that the branch tip now differs from the base, then leaves the worktree with a modified tracked file (`README.md`), a file staged and edited again, a staged file
deleted from disk, an untracked file and a binary file, and runs `abandon` without `--force`. Steps: the goal
approved with the cap; the turn succeeded; the log has real `claude` stream lines (the `turn.started` argv
and the `system/init` line); abandon exit 0; worktree gone; branch kept; `abandon.patch` and
`abandon-staged.patch` exist; `abandon.saved` in `workbench log` with size, sha256, tree and head (and they
match the file); `git apply` of each patch on a fresh checkout of that committed tip (the saved head) restores the
files; no process of the worktree is left; on a pass, removing each restore checkout and the branch.

### grant (P13 task 7)

`goal new` (a goal that asks for `scripts/verify-cli/grant-probe.sh`, then `chmod +x` on it, a compound
`mkdir -p … && touch …` and `rm -rf scratch/grant-probe-dir`, none of which the project's tool set allows), `goal approve`,
`run`, then only workbench commands. Steps: the goal approved with the cap; turn 1 succeeded with denials and
used the real `claude`; `grant --json` lists the chmod as `safe`, open, with the pattern
`Bash(chmod +x scripts/verify-cli/grant-probe.sh)`, and the compound and the `rm -rf` too; the file is there and not
executable; `grant <n> --once` records the pattern; `grant --json` says `granted_once` and
`.workbench/config.toml` is byte for byte what it was; `send-back` runs turn 2, whose `turn.started` argv has the
pattern in `--allowedTools`; turn 2 succeeded and the file is executable; `grant --json` says `open` again
(the grant is spent); refusals: a compound named whole exits 6, a number that does not exist 7, a
number without a scope 2, and the `rm -rf` under `[tools] denied` exits 6 naming `[tools] denied` even with
`--allow-dangerous`, stays open and is not in turn 2's allowed list; the config is still unchanged; no process of the
worktree is left; the thread is ended (`abandon`). `VERIFY_CLI_SABOTAGE=1` revokes the grant (`--never`) before
turn 2, so the argv and executable-bit steps must FAIL. It costs two cheap turns.

### plan (P14 task 5)

`goal new` (a goal that asks for `scratch/plan-probe.txt`), `goal approve`, then `plan <id> --model $MODEL --budget
$BUDGET`, `plan show`, `plan edit`, `plan edit --apply`, `run`, and only workbench commands. Steps: the goal approved
with the cap; the plan turn exits 0; the log has one `plan.started` and then one ok `plan.ended` with the plan file,
its sha256, the goal hash and the base commit; the logged argv has tools `Read Grep Glob` only, safe mode and
`--restricted`; the plan opened no numbered turn; `plans/plan-1.md` is non-empty with no machine path; the
base-commit checkout is gone and not registered with git; `plan show` says `generated` and prints the plan;
`status --json` has `plan.source` `generated`, not stale, and `plan_cost_usd` above 0; `plan edit` writes
`plans/draft.md` equal to the plan; after the script adds a marker line, `plan edit --apply` exits 0 and uses the
draft up; `plans/plan-2.md` holds the marker; `plan show` and `status --json` say `edited`; `plan.edited` names
`plans/plan-2.md`, the plan it came from, the base and the goal hash; `run` succeeds with the real `claude`;
`prompts/turn-1.md` has `## Plan` and the marker; the first `turn.started` has `plan.source` `edited` and the stored
file's sha256; no process of the worktree is left; the thread is ended (`abandon`). `VERIFY_CLI_SABOTAGE=1` changes
`plans/plan-2.md` on disk before `run`, so the plan is left out and the prompt and `turn.started` steps must FAIL.
It costs one cheap plan turn and one cheap coding turn; the summary prints both costs.

### doctor (P15 task 1)

`goal new` (a goal that asks for `scratch/doctor-probe.txt` after reading three files), `goal approve`, then `doctor`
with no turn run, `run` in the background, `doctor` again, `stop`, `doctor` a third time, `abandon`. Steps: the goal
approved with the cap; doctor exits 0 and reports a `check:` line; the thread's log has the same number of lines
after it; no `workbench/doctor` branch or `.workbench/worktrees/doctor` is left, and the thread has no branch yet; the
background run shows a recorded `turn.started` with the real `claude`; doctor then exits 6 and names the thread; after
`stop` there is one `turn.ended` per `turn.started`; doctor exits 0 again and leaves nothing; `abandon` ends the
thread. `VERIFY_CLI_SABOTAGE=1` stops the turn before the second doctor, so the exit-6 and names-the-thread steps must
FAIL. The turn is stopped early, so it costs about nothing.

### help (P15 task 2)

No thread turn is run, so it costs nothing. `goal new` and `goal approve` make a throwaway thread (for the "writes nothing"
step), then every command named in `workbench help` is asked `<cmd> --help`, `<cmd> -h` and `help <cmd>`, in this
repository and in an empty directory. Steps: the commands are listed; all three forms exit 0 with nothing on stderr and
print one text; the text names the command and has `changes:`, `example:`, `--json:` and `exit:` lines; the same text
comes outside a repository and writes nothing there; `help plan` shows every form and `plan show --help` only that one;
help leaves the thread's log and branch alone; `ship --bogus` exits 2 with one stderr line holding the argument, the
synopsis and `(workbench help ship)`; the same with `--json` in `error.message`; `help frobnicate` exits 2 and lists the
commands; plain `help` is still the usage block; `abandon` ends the thread. `VERIFY_CLI_SABOTAGE=1` compares `ship`'s
help with `plan`'s, so the "same text" step must FAIL.

## Adding a scenario for the next feature

One task, one script: `scripts/verify-cli/<feature>.sh`, started with `bash`. Do not copy `abandon.sh`: source
`scripts/verify-cli/lib.sh`, which holds the frame that makes a run safe to repeat, and write only the
scenario: its goal, the state the feature acts on and its checks. `abandon.sh` is the example to read.

```bash
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
preflight                                   # refuses (exit 2) or builds; sets ROOT, WB, SCRATCH, BASE_SHA
start_thread verify-cli-<feature> "$SCRATCH/goal.md"   # goal new, the cap, goal approve; sets ID, BRANCH, THREAD_DIR
remove_on_pass branch "$BRANCH"
run_thread                                  # one real turn, checks it was the real claude; sets WT
# ... the state the feature acts on, the feature's workbench command, one check per step ...
finish                                      # summary, cleanup, RESULT, exit 0 or 1
```

What the frame gives you, and what is left to the scenario:

1. **Refuse first, change nothing** (`preflight`): main checkout, clean, at origin's `main`, no active thread,
   the real `claude`.
2. **Every command bounded**: `with_timeout`, workbench through `wb`, git through `g` (never bare `git`);
   `start_thread` caps the goal at `VERIFY_CLI_BUDGET_USD`, the cheap model and a short `turn_timeout_min`,
   checked after approval.
3. **Workbench commands only for the thread**; `g` or files only to set up the state the feature acts on.
   Read results through `--json` (`status`, `review`, `log`) and the `py` helper, not by parsing text.
4. **One `check "<step>" "<why>" <command>` per thing the plan says the feature does**, so the report reads as
   the task's criteria. Do not leave the outcome to the model: if a step needs a commit or a file, the
   script makes it and checks it, as `abandon.sh` commits `scratch/verify-cli.txt`.
5. **A sabotage switch** (`VERIFY_CLI_SABOTAGE=1`) in the scenario that breaks the feature's output after it
   ran, so a run shows the assertions can fail. `VERIFY_CLI_SABOTAGE=cleanup` (in `lib.sh`) makes a cleanup
   step fail, for any scenario.
6. **Tidy on pass, keep on fail**: register every branch and checkout the scenario makes with
   `remove_on_pass branch|worktree <name>`; `finish` removes them only when every step passed, each as its
   own step, and a removal that fails is a FAIL (exit 1, the rest and the temp folder kept and named). End
   every thread the scenario started and leave no process in the worktree; `finish` prints the cost.

Then add a `### <feature>` section above listing its steps, and put the hand run's output in the PR.
