# P13: Grant

Status: tasks 0 to 4 built; the rest is plan. Written 2026-10-18 after the `verify-cli` threads of 2026-10-17. Closes
FRICTION #1, #28, #29, #33, #34 and #35, which all say the same thing: a run has no prompt path
(`--permission-prompts none`), so a denied command ends the turn's work and the only way on is to edit
`[tools] allowed` by hand, which then stays for every later thread.

## What happened

Eight threads on 2026-10-17, read from `.workbench/threads/*/events.jsonl`:

| Thread | Denied | Why it was denied |
|---|---|---|
| `verify-cli` | `chmod +x scripts/verify-cli/abandon.sh && bash -n … ; shellcheck …; scripts/verify-cli/abandon.sh` | compound; the config only allows `Bash(chmod +x scripts/check.sh)`, one exact file |
| `verify-cli` | `git update-index --chmod=+x …`, `ln -s ../../.agents/skills/verify-cli …` | not on the list |
| `verify-cli-frame` | `cat > f <<'SCRIPT'`, `bash -n …` | heredoc write; `bash -n` (FRICTION #60) |
| six `verify-cli-abandon*` | `mkdir -p scratch && printf … > f && git add … && git commit …` | compound with a redirect; every run tried it, every one was denied once |

Every turn still ended `succeeded`: a denial is not a failure. The user found out by reading the log, and the
file mode of the script was fixed by hand. Three different causes: a prefix that is too narrow, a compound the
allowlist can never match, and a command nobody listed.

## The idea

Denied commands are in the log. `workbench grant` turns them into a decision, per command, with the risk
stated, so the next turn can go on without anyone editing config.

```
$ workbench grant
1  Bash(chmod +x scripts/verify-cli/abandon.sh)   turn 1  safe     allow once | thread | never
2  Bash(git update-index --chmod=+x scripts/…)    turn 1  safe
3  Bash(mkdir -p scratch && printf … && git commit …)  turn 1  caution: compound; grant the parts, not this
```

## Rules

- **The log is the state.** A grant is a `grant.added` event (`scope` `once` or `thread`, the exact tool
  pattern, the denial's `seq`); the next turn's allowed list is the config plus the thread's grants, derived.
  Nothing is written to `.workbench/config.toml` by `grant`.
- **`once`** covers the next turn only. **`thread`** covers every later turn of this thread. **`never`** records
  the refusal so `grant` stops offering it.
- **A grant is a concrete prefix**, never the raw string: `Bash(chmod +x scripts/verify-cli/abandon.sh)`, not a
  loop with a variable. A compound is never granted whole; `grant` says which parts to allow.
- **Classified by rules, not by a model** (FRICTION #34): pipes into a shell, `eval`, `$(…)`, redirects and loop
  variables raise the level; `gh api` with a write method, `--force`, a `+refspec`, `main`, writes outside the
  worktree and an unknown remote are unsafe. Unknown command: caution. Unsafe needs `--allow-dangerous`, once only.
- **A push stays in `ship`** unless the thread opts in (FRICTION #35).
- **No terminal is assumed.** Every choice is a flag (`grant 1 --once`), because runs are driven by Claude or by
  `!`. Without flags and with a terminal, it asks.
- The repo config is only ever *suggested*: a narrow safe prefix, after it was denied or granted more than once.

## Tasks

0. **Record the full denied command.** Done (#123): `turn.ended.denials`, the command up to 4096 characters.
1. **`review` shows the full denied command**, wrapped, from `turn.ended.denials`, falling back to the `claude`
   line for older logs. Done (#125). Numbering the entries moves to task 4, where the numbers are used.
2. **The classifier.** Done (`Sources/WorkbenchCore/Grant/`). A pure function: command → `safe | caution | unsafe`, the reason, and the concrete prefix to
   grant (nil for a compound). Table-driven tests from the eight threads above, and the cases in FRICTION #33–35.
3. **`grant.added` and the allowed list.** Done (`GrantLedger`). Event kind and spec; `ThreadState` derives the grants; the turn's
   invocation adds them (`once` expires when the next turn ends). Tests: a grant reaches `--allowedTools`; `once`
   is gone one turn later; a denied pattern in `[tools] denied` is never overridden by a grant.
4. **`workbench grant`.** Done. List, `grant <n> --once|--thread|--never`, `--allow-dangerous`, `--json`. Refuses a
   decided thread or a running turn.
5. **`run` says it.** A turn that ended with denials prints "N denied, `workbench grant` to review", and the
   first prompt's tool note tells the model that a denied command is granted by the user, not worked around.
6. **Suggest the repo config** after repeats. Print the line to add; never write it.
7. **`verify-cli` scenario** for grant on the real `claude`.

## Acceptance

- A turn denied `chmod +x scripts/x.sh` is granted with one command and the next turn runs it.
- `once` does not outlive a turn; `thread` does not outlive the thread; `[tools] denied` always wins.
- The classifier is rules only and its output is the same for the same input.
- No grant is ever written to config by `grant`.

## Open questions

- Should `once` mean the next *turn* or the next *use* of the command? Turn is simpler and the log can tell.
- Does a `thread` grant carry over to a copy made with `goal new --from`? Proposed: no.
