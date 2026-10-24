# P9 task 1: capability matrix

Run 2026-10-24 against `claude` **2.1.310** and `codex-cli` **0.163.0** (Gemini is not installed, so it is
not probed). Driver: [`P9-probes/scripts/probe.py`](P9-probes/scripts/probe.py); raw transcripts and the
result tables: [`P9-probes/fixtures/`](P9-probes/fixtures/). Each probe is a real turn on a throwaway repo
with a tracked, an ignored and a new path, a bare remote, and a directory under `$HOME` (not `$TMPDIR`,
which `workspace-write` makes writable). The outcome is read from the filesystem and the remote after the
turn, not from what the model said.

Costs: about 8 Claude `haiku` turns capped at $0.25 each, and about 60 Codex turns on a ChatGPT login (two
runs, because the first had a flawed probe; see "What the probes got wrong").

## Matrix

| Capability | Claude 2.1.310 | Codex 0.163.0 |
|---|---|---|
| Read-only, writes (tracked, untracked, ignored, outside the repo) | Refused: no write tool exists (`--restricted --tools Read,Grep,Glob`) | Refused with `-s read-only`, **only when the user config is ignored** (below) |
| Read-only, reads outside the repo | **Refused** (`Read` is confined, listed in `permission_denials`) | **Allowed**: `cat <outside>/secret.txt` returned the secret in every mode |
| Read-only, `git commit` | No Bash tool | Blocked (`.git/index.lock: Operation not permitted`), hardened only |
| Read-only, `git push` of an existing commit | No Bash tool | Blocked, hardened only (the remote is outside the writable roots) |
| `workspace-write`, `git push` of an existing commit | No Bash tool | **Succeeded** even hardened, to a local-path remote under `$TMPDIR`. A GitHub remote would also need network (off hardened) and credentials; not probed |
| Coding confinement | Confined to the worktree by `--restricted` (P1 spike S3) | `-s workspace-write`: repo writes allowed, writes outside refused, network refused (hardened); **`.git` is not writable**, so the agent cannot commit |
| Network from the sandbox | No shell tool in read-only; not probed for coding | Off by default; the user config here turned it on (`[sandbox_workspace_write] network_access = true`) |
| Hard dollar cap | `--max-budget-usd` (`error_max_budget_usd`) | **None.** No flag; `turn.completed.usage` has token counts only, no cost |
| Usage reporting | `result.total_cost_usd`, tokens | Tokens only |
| Native resume | Caller supplies `--session-id`, then `--resume` | Id is **returned** (`thread.started.thread_id`), resume with `codex exec resume <id>`; the caller cannot choose it |
| Resume of a one-shot | `--no-session-persistence` | `--ephemeral` writes nothing; resuming its id fails (exit 1) |
| Image input | Read tool on a path | `-i <file>`: read `PELICAN-7731` from a PNG correctly |
| Structured final answer | `--json-schema` | `--output-schema` with `-o <file>`: `{"verdict":"CLEAN"}` |
| Streaming | `stream-json` | `--json` JSONL: `thread.started`, `turn.started`, `item.*`, `turn.completed` |
| Auth environment | Not probed here (P1 settled `env_pass`) | Works with an **empty environment**: it finds its login itself, so no variable has to be passed |

## Findings that change the plan

1. **A user's Codex setup can defeat the sandbox flag.** This machine has `approval_policy = "on-request"` and
   `approvals_reviewer = "auto_review"` in `~/.codex/config.toml` and a `~/.codex/rules/default.rules`. With them, `-s read-only` and
   `-s workspace-write` both let `git commit && git push origin main` through: the sandbox refused, the
   command re-ran outside it, and the remote's `main` moved in both runs. With
   `--ignore-user-config --ignore-rules -c approval_policy="never"` the same attempts fail. A follow-up probe
   isolated the cause: `--ignore-rules` alone stops the push, while keeping the config and setting only
   `approval_policy="never"` does not. The user's exec-policy rules are what let it through. The production review's exact flags
   (`--ignore-rules -c approval_policy="never"`, config kept) block all four attempts; results in
   `P9-probes/fixtures/review/`.
   **Workbench's review passed only `exec -s read-only -C <tree> --color never --ephemeral -o <file>`, so it was
   exposed to this; it now adds `--ignore-rules -c approval_policy="never"`.** The adapter in task 2 must state the policy on
   the command line and ignore user config; the fix for the existing path should not wait for P9.
2. **Codex cannot confine reads.** Claude's `--restricted` stops a judge or reviewer reading
   `~/.ssh` or another repo; Codex's `read-only` does not. D8 says unsupported combinations fail
   explicitly, so a Codex judge/review must either be accepted with this stated limit or refused. That is
   a user decision for task 3; the matrix only records it.
3. **No dollar cap on Codex.** Confirms the plan's premise: Codex coding, judging and review all need the
   explicit no-cap approval that PR 2 specifies. A timeout is the only bound.
4. **Codex coding cannot commit inside `workspace-write`.** `.git` is read-only, so a Codex coding turn
   leaves changes uncommitted. Check how the Claude path hands changes over (the worktree is committed by
   Workbench or by the agent) before PR 11; it may be fine, but it is a difference.
5. **Session ids flow in opposite directions.** Claude takes one from the caller, Codex returns one. The
   plan's "prepared but unconfirmed handle recorded before spawn" works for Claude only; for Codex there is
   nothing to record before the first `thread.started`, so crash recovery after a Codex first turn that
   never printed it must start a fresh session.

## Pins

- Claude **2.1.310**, Codex **0.163.0** (probed). Minimums are not yet decided: older versions were not
  tried, so "at least these" is a claim this document cannot make. Re-run `probe.py` when either CLI's
  flags change.
- Codex hardened invocation used for the pass/fail rows:
  `codex exec --json --color never --skip-git-repo-check --ephemeral -C <dir> -s <read-only|workspace-write>
  --ignore-user-config --ignore-rules -c approval_policy="never" -- <prompt>`.

## What the probes got wrong, and what is still open

- The first combined `git commit && git push` attempt never tested push alone: when the commit was denied, push
  did not run. PR review caught it; `git_push_only` pushes a commit made before the turn and compares the
  remote's `main` with the local `HEAD` (`P9-probes/fixtures/push/`).
- The first run put the outside directory under `$TMPDIR`, so a `workspace-write` write there succeeded
  because the sandbox allows it. The second run moved it under `$HOME`.
- `codex exec --json` does not emit a `command_execution` item when the sandbox refuses a command, so
  "no command ran" is not evidence the model did not try. Rows are judged by effects, and the final
  message in each `*.stdout` says what the model reported.
- **`gh pr comment` is inconclusive.** It failed because the throwaway repo's remote is not a GitHub
  remote, not because anything was enforced. Posting is blocked in Workbench by not giving the agent
  credentials (the host-owned credential boundary), which this probe does not test. Task 3 should test it
  against a stub `gh` that records calls.
- Not probed: Codex coding with a real edit-and-test loop (only forbidden actions were tried), Claude
  auth variables, Gemini, older CLI versions, and Codex's behaviour when `$CODEX_HOME` is unset or
  unwritable.
- The Codex runs without `--ignore-user-config` added `[projects."…/p9-…"]` trust entries to
  `~/.codex/config.toml`. The driver now cleans only its temporary directories; remove those entries by
  hand after an `asconfigured` run (this run's were removed). A Codex run on a project mutates the user's
  config, which an adapter should avoid with `--ignore-user-config`.

## Open questions from the plan

- **Which versions provide the boundaries?** Answered for the two probed versions above; the minimum is
  open.
- **Goal-file form of explicit no-cap approval:** not answered here; PR 2.
- **Event version 1 stays additive?** Not answered here; PR 2.
