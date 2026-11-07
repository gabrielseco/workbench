# P24: Permissions auto

Status: built (spike run on `claude` 2.1.319, 2026-11-07). Closes the approval treadmill: a run starts `claude` with
`--permission-prompts none --restricted --allowedTools <list>`, so every command outside the list is denied and only
`workbench grant` (after the fact) or an edit of `[tools] allowed` gets it through. Compound commands (`a && b`),
heredocs and redirects can never match a prefix list (P13 task table), and a worktree is already a throwaway place.

## The idea

`permissions = "auto"` in `.workbench/config.toml` (top level, next to `check_command`). A run then also passes
`--permission-mode auto`: `claude`'s own classifier decides which commands are safe, as it does in an interactive
session. Default is `permissions = "allowlist"`, today's behaviour byte for byte.

## Spike (claude 2.1.319, haiku, a scratch git repo, `-p --restricted --safe-mode --permission-prompts none`)

| Run | Flags added | Result |
|---|---|---|
| A | `--permission-mode auto`, prompt: `mkdir x && printf a > x/f && git add x` | ran; init says `permissionMode: auto`; no denial |
| B | none (allowlist, same prompt) | denied: in `permission_denials` |
| C | auto + `--allowedTools 'Bash(git push:*)'` + `--disallowedTools 'Bash(git push:*)'` | denied: the deny wins over an allow |
| D | auto + `--disallowedTools 'Bash(git push:*)'` | denied: the deny wins over the classifier |
| E | auto, `echo hi > <a path outside the repo>` | **ran**: the file was written |

What it shows: `auto` is accepted together with `--restricted`, `--safe-mode` and `--permission-prompts none` (unlike
`bypassPermissions`, which `--restricted` refuses); a refusal looks the same as today (`permission_denials` with
`tool_name`, `tool_input.command`), so `turn.ended.denials`, the activity feed and `workbench grant` need no change; a
deny rule still wins.

Not measured: a command the classifier itself rejects. `curl … | sh` was stopped by the classifier of the session that
was running the spike and was not worked around; two harmless probes, `git push --dry-run --force origin main` and
`chmod -R 777 <missing dir>`, were both **allowed** (runs G, H), and nothing riskier was tried. A rejection is expected
to arrive as a `permission_denials` entry too, since that is how every denial arrives; if a run shows otherwise,
`grant` will not list it and this plan needs a task. The PR says this is unproven; it is the first thing to check
the day a run is refused under `auto`.

## Known limit

`--restricted` confines the **file tools** to the worktree, not Bash (run E). Under `auto` a Bash command the
classifier judges safe can write outside the worktree. What stays: the classifier, `[tools] denied` (always wins),
the minimal child environment (no `SSH_AUTH_SOCK`, no cloud or token variables), `git push` staying in `ship`, and the
review of the diff. A sandbox that bounds Bash to the worktree (Seatbelt with `bypassPermissions`) is a separate task,
not this one; it needs `--restricted` lifted.

## Tasks

1. **The key and the flag.** Done. `PermissionsMode` (`allowlist` | `auto`), parsed from the top level (any other value
   is a problem naming the line), `--permission-mode auto` in the run's argv and nothing else changed; `workbench
   config` prints `perms:`. Tests: `ConfigTests`, `InvocationTests`, `EnvironmentTests`.
2. **`verify-cli` scenario** `scripts/verify-cli/permissions-auto.sh` on the real `claude`: the compound command runs,
   `git push --dry-run` is denied, the log names it. `VERIFY_CLI_SABOTAGE=1` leaves the key out and fails the steps that
   need it.

## Acceptance

- Without the key, a run's argv is what it was. With `auto`, it adds `--permission-mode auto` and nothing else.
- `[tools] denied` still denies under `auto`; a denial is still recorded and listed by `grant`.
- The verifier, the plan turn, the review and the goal agents do not change (their argv builders do not read the key).

## Open questions

- Should the app's run settings show the mode? Read-only, if cheap; later otherwise.
- Should `auto` be the default for a new project's template? Not here: opt in first.
