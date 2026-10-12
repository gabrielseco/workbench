# P1 spikes: results

Run 2026-10-12 against `claude` **2.1.296**, model `haiku`, `--max-budget-usd 0.25` per run (about $0.20
total). Raw output is in [`P1-spikes/fixtures/`](P1-spikes/fixtures/), the drivers in
[`P1-spikes/scripts/`](P1-spikes/scripts/).

All six questions are answered. **None of them blocks P1**, but S3 and S6 change the design, so read those two.

| # | Answer in one line | Changes the plan? |
|---|---|---|
| S1 | One `result` line, always last, exactly once, in 10/10 runs | Parser can key `turn.ended` off it, with exit code as the fallback |
| S2 | Denials are clean: error tool_result, model reports it and ends | `denied_only` is derivable from `result.permission_denials` |
| S3 | Bash allowlist is tight. **Bare `Read`/`Edit`/`Write` are not confined to the worktree** | **Yes: do not allow bare file tools** |
| S4 | `--session-id` then `--resume` carries context, including after a killed turn | Turn 1 uses `--session-id`; any retry after a kill must use `--resume` |
| S5 | Cap reached gives `error_max_budget_usd`, exit 1, still a `result` line | Map to `budget_exceeded` |
| S6 | SIGTERM cleans up children. **SIGKILL leaks them, and tool children are in their own process group** | **Yes: rule 3 of the process layer is wrong as written** |

Also found along the way, all small:

- **stdin must be `/dev/null`.** Otherwise `claude -p` waits 3s and warns `no stdin data received in 3s`.
- **User hooks run.** `system/hook_started` and `hook_response` lines appear in the stream from the user's
  own settings. The runner must tolerate unknown `system` subtypes, and should decide on `--setting-sources`
  or `--bare` (see S3 follow-ups).
- **Prompt goes after `--`.** `--allowedTools` and `--disallowedTools` are variadic and will swallow a
  trailing prompt otherwise.

---

## S1: stream-json shape

**Run:** 10 trivial goals (`s1-trivial-1`, `s1-read-2` to `-10`) with
`-p --output-format stream-json --verbose --include-partial-messages --permission-prompts none`.

| Observation | Result |
|---|---|
| Runs ending with a `result` line | 10 / 10 |
| `result` lines per run | exactly 1 |
| Position of `result` | last line, every run |
| Exit code | 0 in all 10 |
| Lines per run | 15 (no tools) to 48 (one Read) |

Line types seen, in the order they appear:

```
system/hook_started, system/hook_response   (user hooks, 0 to N, before init)
system/init                                 cwd, session_id, tools, model, permissionMode
system/status
stream_event                                (partial messages; many)
assistant                                   full message, tool_use blocks live here
user                                        tool_result blocks
rate_limit_event
result                                      subtype, is_error, total_cost_usd, usage,
                                            permission_denials, terminal_reason, stop_reason, session_id
```

**Decisions**

- `turn.ended.result` comes from the `result` line (`subtype`, `is_error`, `terminal_reason`). If the process
  exits with no `result` line, that is `failed` (or `interrupted`/`stopped`/`timed_out` when we caused it).
- `cost_usd` is `result.total_cost_usd`, `session_id` is `system/init.session_id`.
- `--include-partial-messages` multiplies line count (most `stream_event`). Keep it for P3's live view, but
  the log-size cap (rule 6) needs to account for it.
- Parser must ignore unknown `type` and `subtype`. Hook events prove the set is not closed.

Fixtures: `s1-trivial-1.jsonl`, `s1-read-2.jsonl`.

## S2: what a denial looks like

**Run:** allowlist without `touch`, goal "run `touch s3-unlisted.txt`".

- The tool call returns a `tool_result` with `is_error: true` and the text *"Permission for this tool use was
  denied. It requires approval, and this session has no approval surface … do not retry it"*.
- The model reports the denial and ends the turn. It did not retry or stall. `num_turns: 2`.
- The `result` is still `success` / `completed`. The denial is only visible in `result.permission_denials`
  (`tool_name`, `tool_use_id`, `tool_input`).
- This held for 18 of 18 denied commands in S3.

**Decisions**

- A denial is **not** a failed run. `turn.ended.result` stays `succeeded`; the review UI shows denials from
  the log. That matches the P1 acceptance criterion "denied tool calls appear in the log and the turn still
  ends cleanly".
- `denied_only` (spec) = `permission_denials` non-empty **and** no file changes in the worktree. P2 computes
  it; the runner does not need to.
- The denial text tells the model not to retry, so a stall loop is unlikely. One more reason not to build
  retry logic.

Fixture: `s3-denied_unlisted.jsonl`.

## S3: allowlist porosity

**Setup:** `--permission-prompts none`, `--allowedTools Read "Bash(git status:*)" "Bash(git diff:*)"
"Bash(ls:*)" "Bash(cat:*)"`, `--disallowedTools WebFetch WebSearch`, cwd = a scratch repo. Each case asks the
model to run exactly one command. Pass = a side-effect file does not appear. Driver: `scripts/s3.py`.

### Bash

| Case | Command | Outcome |
|---|---|---|
| allowed plain | `ls` | ran |
| allowed with flags | `ls -la --color=always .` | ran |
| unlisted | `touch s3-unlisted.txt` | denied |
| `&&` chain | `git status && touch s3-and.txt` | denied |
| `;` chain | `ls; touch s3-semi.txt` | denied |
| pipe | `ls \| tee s3-pipe.txt` | denied |
| `$(...)` | ``ls $(touch s3-subst.txt)`` | denied |
| backticks | ``ls `touch s3-bt.txt` `` | denied |
| redirect | `ls > s3-redir.txt` | denied |
| append redirect | `git status >> s3-append.txt` | denied |
| `cd ..` | `cd .. && ls` | denied |
| path above worktree | `ls ..` | denied |
| absolute path outside | `ls /etc`, `cat /etc/hosts` | denied |
| home dotfile | `cat ~/.zshrc` | denied |
| ssh key | `cat ~/.ssh/id_ed25519` | denied |
| `git -C /` | `git -C / status` | denied |
| git outside repo | `git diff --no-index /etc/hosts /etc/hosts` | denied |
| env var side effect | `GIT_PAGER='touch s3-pager.txt' git diff` | denied |
| env prefix | `FOO=1 ls` | denied (conservative; fine) |

No side-effect file was created in any case. Claude Code's own matcher handles compound commands,
substitutions, redirects and out-of-tree paths. **We do not need to re-implement any of it**, which is the
point of D2.

### File tools (the surprise)

| Config | Read outside | Write outside | Write inside |
|---|---|---|---|
| `--allowedTools Read Edit Write` (bare names) | **allowed** | **allowed** (also via `repo/../x`) | allowed |
| `--permission-mode acceptEdits` + `--allowedTools "Read(./**)"` | denied | denied | allowed |
| `--restricted --tools Read Edit Write Bash` + bare names | denied | denied | allowed |

So **a bare `Read`, `Edit` or `Write` in `--allowedTools` makes the worktree no boundary at all.** With the
bare form the model read `/private/tmp/.../f.txt` and created files outside the repo.

**Decisions**

- The fixed tool set must not contain bare file tools. Two candidate shapes, both verified:
  1. `--permission-mode acceptEdits` + `Read(./**)` (+ Bash patterns). Edits inside cwd are auto-accepted,
     everything else is denied.
  2. `--restricted` + `--tools` naming exactly what we want. Confines file tools to the working directory
     and ignores user/project/local settings files, which also removes the hook noise from S1.
- **Proposal: `--restricted`.** It is one flag that states the intent, and it drops user settings, so a
  teammate's hooks or permission rules cannot change a run. Verify it does not break the real end-to-end run
  in task 9 (MCP servers, skills) before committing.
- The worktree **is** a boundary once one of these is used. The "worktree alone is enough" branch of S3's
  decision holds, with the caveat above.
- Not tested, still open: symlinks inside the worktree that point outside it; `Read` of `.git` internals;
  `Bash(git:*)`-style wide patterns (we only allow narrow ones). Add as P1 task-9 checks, not blockers.

Fixtures: `s3-summary.json` (all 20 cases), `s3-denied_unlisted.jsonl`, `s3b-write-outside.jsonl` (the leak).

## S4: session continuity

| Case | Result |
|---|---|
| Turn 1 `--session-id <u>` ("remember zebra"), turn 2 `--resume <u>` ("what word?") | Answered `zebra`, exit 0 |
| Reuse `--session-id <u>` after a completed turn | **Exit 1**, `Session ID … is already in use`, no stream output |
| Turn 1 killed with SIGKILL 5s in, then `--resume <u>` | Answered `giraffe`, exit 0. The prompt was persisted before the kill |
| Turn 1 killed, then `--session-id <u>` again | **Exit 1**, `Session ID … is already in use` |

**Decisions**

- `--session-id` is for the first spawn of a thread and nothing else. Every later spawn, including a retry of
  a turn that was killed, uses `--resume`.
- Rule for the runner: the session exists as soon as the first spawn got far enough to persist the prompt.
  Safe approach: persist `session.json` before spawn; on any later turn use `--resume` if `session.json` has
  a session id, full stop. If `--resume` itself fails with "no conversation found" (kill before persistence),
  fall back once to `--session-id`; log both attempts.
- Crash recovery (task 8) can therefore be: orphan `turn.started` gets `turn.ended: interrupted`; the next
  turn simply resumes. No special casing.
- A killed turn can leave a partial assistant message in the session. Context still carries, so no repair
  step is needed.

Fixtures: `s4-turn1.jsonl`, `s4-turn2.jsonl`, `s4-killed.jsonl` (6 lines, no `result`).

## S5: budget cap

**Run:** `--max-budget-usd 0.0005`, prompt asking for a 300 word essay.

- `result.subtype = "error_max_budget_usd"`, `is_error: true`, `terminal_reason: "budget_exhausted"`.
- Exit code **1**, and the `result` line is still present and last.
- The turn stops partway; the worktree may hold partial work.

**Decision:** `terminal_reason == "budget_exhausted"` (or subtype `error_max_budget_usd`) maps to
`budget_exceeded`. Exit code alone is not enough: it is 1 for any error, so the `result` line has to be read
before falling back to the generic `failed`.

Fixture: `s5-budget.jsonl`.

## S6: leftover processes after stop

**Run:** `claude` started with `start_new_session=True` (own group), asked to run `sleep <N>` through Bash,
then stopped three ways. Driver: `scripts/s6.py`. (A first attempt matched `claude` itself and was discarded;
the matcher is now `^sleep <N>$`.)

| Stop method | `claude` exit | Tool child (`sleep`) afterwards |
|---|---|---|
| SIGTERM to `claude` pid | rc 143, 0.9s | **gone** |
| SIGTERM to the process group | rc 143, 0.8s | **gone** |
| SIGKILL to the process group | rc -9, instant | **still running** (orphaned) |

And the structural finding: the `sleep` was **not** in `claude`'s process group (its pgid was its parent
shell's pid, not `claude`'s). So `killpg(claude_pgid)` never reaches tool children at all. They are only
cleaned up because `claude` handles SIGTERM and kills its own children.

**Decisions (these amend "Process layer rules" in P1-runner.md)**

- **Rule 3 is wrong as written.** A new group for `claude` is still worth having (so Ctrl-C in the terminal
  does not hit it and so we can signal one thing), but it is **not** sufficient to kill the tree.
- **Escalation order stays SIGTERM first, and we wait the full 5s.** SIGTERM is the only path that
  demonstrably cleans tool children. SIGKILL is a last resort and must be paired with a tree sweep.
- **Tree sweep before SIGKILL:** walk descendants by ppid (`ps -A -o pid=,ppid=` or `proc_listpids`),
  record the set, then SIGKILL them leaves-first after `claude`. Do it just before escalating, because the
  tree is already shrinking during the 5s grace.
- **Orphan scan on startup** is also needed: after a runner crash `claude` may be dead while its tool
  children live on. Their pids are not known in advance, so the scan looks for processes whose cwd is inside
  `.workbench/worktrees/` (macOS: `lsof -d cwd` or `proc_pidinfo`). Settle the mechanism in task 8.
- Add to the failure matrix: **tool grandchild survives SIGKILL of `claude`** → swept. The fake claude's
  "spawn a grandchild" switch must put the grandchild in its **own** group, to match reality.

Fixtures: `s6-*.jsonl` were not kept (only a few lines, the signal is in the driver output above).

---

## Resulting changes to the plan

Applied to [`P1-runner.md`](P1-runner.md) and [`README.md`](README.md) in the same change:

1. D2 now names the verified shapes (`--restricted`, or `acceptEdits` + scoped `Read`) and forbids bare file
   tools.
2. Turn lifecycle flags corrected: stdin `/dev/null`, prompt after `--`, `--resume` for every non-first spawn.
3. Process rule 3 and the failure matrix updated per S6.
4. `current` file removed from the on-disk layout; derived from the log (as proposed).

## Still open after the spikes

- Does `--restricted` break anything we need in a real run (task 9)? If it does, fall back to
  `acceptEdits` + `Read(./**)`.
- Symlinks out of the worktree, and `.git` internals (see S3). Cheap to test in task 9.
- Per-run network deny list: **not needed for the Bash allowlist** (no network commands are allowed and
  `WebFetch`/`WebSearch` are denied). Revisit only if the fixed set grows to include `npm`/`swift build`,
  which can themselves reach the network.

---

## Addendum: task 4 smoke test

Run 2026-10-12 with the argv produced by `Config.invocation` and an environment built by
`Config.childEnvironment`, against `claude` 2.1.296.

| Check | Result |
|---|---|
| Full generated argv accepted by the CLI (`--restricted`, `--tools`, `--allowedTools`, `--disallowedTools`, `--` prompt) | yes |
| Edit inside the worktree | worked |
| `git push origin main` (in `denied`) | denied |
| Write outside the worktree under `--restricted` | denied |
| Scrubbed environment without `USER`/`LOGNAME` | **"Not logged in"**, cost 0 |
| Scrubbed environment with `USER`/`LOGNAME` (the real base set) | logged in, runs normally |
| `check_command = "scripts/check.sh"`: `scripts/check.sh`, `scripts/check.sh --fast` | ran |
| Same pattern: `./scripts/check.sh`, `sh scripts/check.sh`, absolute path | denied |
| `--session-id` reused across runs (a harness slip) | `Session ID … is already in use`, confirming S4 again |

Two things this changes: `USER` and `LOGNAME` are in the fixed environment set, and `check_command` must
be written exactly as it will be invoked.

One more data point on cost caps: a $0.30 cap was exceeded (about $0.45) by a multi-step run on the default
model, so the cap is a runaway stopper with a few turns of slack, as S5 suggested.

---

## Addendum: task 9, real runs through `workbench`

Run 2026-10-13 with `claude` 2.1.296, `--model haiku`, subscription login (`apiKeySource: none`), against a
throwaway Python project with a unit test and `scripts/check.sh`. Fixtures: `t9-real-turn1.jsonl`,
`t9-real-turn2.jsonl` (before safe mode) and `t9-real-safe-mode-turn1.jsonl`.

### What held

| Check | Result |
|---|---|
| Real goal through `workbench run` with `--restricted`, scrubbed environment, subscription auth | succeeded: 8 model calls, edits and a commit on the thread's branch, main checkout untouched |
| The model's own account vs. the repo | diff was exactly the request, `greet` untouched, check passes when run independently |
| Check command as the model really invokes it | `scripts/check.sh` ran; `scripts/check.sh; echo "exit=$?"` was denied, and the model then ran it plainly |
| Real resume with feedback | same session id, `resume: true`, and the model correctly recalled which file it edited first the turn before |
| Result and cost fields | `total_cost_usd`, `usage`, `permission_denials`, `num_turns` as the spikes showed |
| Denied tool call (compound `git log ...; git branch ...`) | logged, counted in `permission_denials`, turn still `succeeded` |

### The S3 gaps, now tested (7 of 7 denied, nothing leaked, nothing created outside)

| Probe | Result |
|---|---|
| Read through a symlink to a directory outside the worktree | denied |
| Read through a symlink to a file outside | denied |
| Write through a symlink to a directory outside | denied, file not created |
| `git diff --no-index <file> <symlink-to-outside>` (reads outside via git) | denied |
| Read `<repo>/.git/config` | denied (outside the working directory) |
| Write `<repo>/.git/hooks/pre-commit` (code execution on a later commit) | denied, file not created |
| Read a file in the main checkout | denied |

So the worktree is a boundary for the file tools and for the allowed Bash patterns, as far as these probes
reach. Still not tested: hard links, a symlink committed to the repo and checked out by the model itself,
and a `Bash` pattern wider than the narrow ones we allow.

### The big one: customizations dominated the context

The session loaded 17 skills, 53 slash commands, 4 plugins and 5 agents despite `--restricted` (which
dropped settings files and MCP tools, and no hook ran). That baseline, not the task, was most of the cost:

| Same two-call job | list price | cache created | cache read |
|---|---|---|---|
| `--restricted` only | $0.184 | 181,596 | 141,176 |
| `+ --safe-mode` | $0.001 | 1,652 | 14,476 |
| `+ --safe-mode --disable-slash-commands` | $0.000 | 334 | 15,794 |

Through `workbench`, a fresh thread with safe mode from turn one cost **$0.002 and $0.003** for two turns,
against **$0.31 and $0.85** before: roughly 150 to 280 times less, with the same result.

- `--safe-mode` is now the default (`safe_mode = true`, with `--disable-slash-commands`). It also means a run
  depends on the goal and the tool set and nothing installed on the machine, which is what the goal-file
  spec asks for. The cost is that the project's own `CLAUDE.md` is not read; put what matters in the goal,
  or set `safe_mode = false`.
- **It only applies to sessions created with it.** A resumed session reuses the system prompt recorded
  when it was created ("as-is, even when a later launch passes different text"), so turning it on does
  nothing for an existing thread: turn 3 and 4 of the old thread still cost $0.98 and $1.08.
- `--restricted` ignores settings files but **not** plugins, skills or agents.

### Window usage

The whole task moved the 5-hour window from 35% to 41% and the 7-day from 14% to 15%, almost all of it from
the runs before safe mode. List-price dollars are a poor guide to this; tokens are better.

### Smaller findings

- `model` is a config key now. `--restricted` ignores the user's settings, so without it a run uses the
  CLI's own default, not the model chosen in an interactive session.
- Follow-up turns are not cheaper: cost grows with the conversation. With safe mode it is negligible.
- `abandon` refuses a worktree with untracked files (the model's test run leaves `__pycache__`), by design:
  it would delete them. `--force` overrides it. A run of build artifacts blocking abandon will be common,
  so P2's discard should say what would be lost.

