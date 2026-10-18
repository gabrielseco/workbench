# P14: A plan turn before the first run

Status: tasks 1 to 4 built (`workbench plan`, `plan_model`, `plan.started`/`plan.ended`, the plan in the run's first prompt, `plan show`, `plan edit`). Written 2026-10-18. Independent of [P9](P9-agent-providers.md), but shaped so P9 can
give it a provider. Builds on the judge (a separate read-only `claude -p` run with its own budget and events) and
on the per-role model keys (`judge_model`, `describe_model`, #126).

## Why

A run is one long, expensive loop: read the repo, decide an approach, edit, check, retry. On a big model every
retry pays for the same context. Two things we want to try, and cannot today:

1. **A stronger model decides, a cheaper one types.** Opus (or another model) reads the repo against the approved
   goal and writes the approach; Sonnet carries it out. Safe mode keeps Claude's own `opusplan` from helping: it
   switches model only inside plan mode, and Workbench never starts a turn in plan mode, so `model = "opusplan"`
   is Sonnet for the whole run (probed 2026-10-18: default mode used `claude-sonnet-5-5` only, plan mode
   `claude-opus-5-5` only). The split has to be Workbench's.
2. **A person reads the approach before any edit is made.** A plan that misreads a criterion is cheap to catch in
   text and expensive to catch in a diff.

The goal file stays what it is: the request, the checkable criteria, what is out of scope, approved by the owner
and bound to its hash. A plan is not part of it and cannot change it.

## The idea

```
goal (write, check, approve)  ->  plan (read-only, own model)  ->  run (coding model, plan in the first prompt)
                                       |
                          you read it: `plan show`; change it: `plan edit`; redo it: `plan --again`
```

`workbench plan [id]` runs one read-only `claude -p` turn, **not a numbered coding turn**, as `judge` does. It reads
the repository at the thread's base commit and ends with a short plan. The next `workbench run` puts the latest good
plan into the first prompt. There is no approval step: you read it if you want to, and edit it if it is wrong.
Nothing gates on the plan: a thread without one runs as today, and `run --no-plan`
skips one that exists.

|  | plan (this phase) | judge (built) | run (built) |
|---|---|---|---|
| Reads | the base commit, the goal | the diff, check and proof | the worktree |
| Tools | `Read`, `Grep`, `Glob` | none, or `Read` on screenshots | the project's `[tools]` |
| Model | `plan_model`, else `model` | `judge_model`, else `model` | the goal's `model`, else `model` |
| Writes | nothing but its answer | nothing but its answer | the worktree |
| Numbered turn | no | no | yes |

## Rules

1. **Needs an approved goal.** `plan` on a draft, or on a goal edited since approval, is refused with what to do.
   It costs money, so it only runs on a goal the owner has already stood behind.
2. **Read-only by construction, not by prompt.** `--restricted`, `--tools Read,Grep,Glob`, no `Bash`, `Edit` or
   `Write`, `--permission-prompts none`, safe mode on. It does **not** use `--permission-mode plan`: in `-p` that
   adds a plan-approval step that nothing answers, and the tool list already makes it read-only. A test asserts the
   argv.
3. **It reads a checkout of the base commit, not the main checkout and not the worktree.** The worktree does not
   exist before the first run, and the main checkout holds whatever the owner is editing. A detached checkout of
   the recorded base commit goes in the thread's `plan/` folder, is the turn's working directory (so `--restricted`
   confines `Read` to it), and is removed on every ending. `OrphanSweeper` ends a `claude` a killed plan left there.
4. **The plan is advice to the coder, never an instruction over the goal.** The first prompt says it is a plan made
   by another model, that the criteria and out-of-scope list win where they disagree, and that a deviation is to be
   said in the turn's summary. It cannot change the budget, the tools, the model or the criteria.
5. **A plan belongs to a goal and a commit.** `plan.ended` records the goal's approved hash and the base commit. A
   plan whose hash is not the approved goal's is not injected and `run` says so. A base that has moved since is
   noted in the prompt ("planned at `abc123`"), not refused.
6. **Bounded.** Plan text is cut at 16 KB with a marker, the turn has a budget (default $1.00) and a timeout
   (default 10 minutes), the output line size is capped as for the judge. Machine paths and credentials are
   scrubbed from the stored text (`PRBodyBuilder.scrub`).
7. **A plan always ends, and says how.** `plan.started` is followed by exactly one `plan.ended`, also on stop,
   timeout, crash and restart recovery (the next command that opens the log writes the missing `plan.ended` with
   reason `interrupted`).
8. **One holder.** The log is held while it runs, as for the judge: a run, a judge or a second plan is `busy`, and
   `stop` reaches it through `runner.json`.
9. **The log is the state.** The plan text is a file (`plans/plan-N.md`, like `prompts/turn-N.md`) referenced from
   `plan.ended` with its sha256 and size; no second copy is stored in `session.json` or the goal.

10. **A plan can be edited, and an edit is a new plan.** `plan edit` copies the latest plan to `plans/draft.md`;
    you edit that file and `plan edit --apply` (or `plan edit --from <file>`) records it as the latest plan with a
    `plan.edited` event; the generated one stays in the log. The next `run` uses whichever is latest. An edit is
    bounded, scrubbed and bound to the goal hash and base commit exactly like a generated plan, and an unchanged
    text records nothing. It costs nothing, runs no process, and so has no `started`/`ended` pair. No `$EDITOR` is
    started: every child Workbench runs has stdin on /dev/null and no terminal, and the banned-API script forbids
    another way.

## The seam for other providers

The plan logic never builds a `claude` command itself. It calls one function:

```swift
struct ReadOnlyRequest { prompt, workingDirectory, model, budget, timeout }
struct ReadOnlyAnswer  { text, costUSD, reason }       // reason set when the answer is not usable
typealias ReadOnlyAgent = (ReadOnlyRequest) async -> ReadOnlyAnswer
```

The first implementation is Claude (argv, the `--output-format json` envelope, the spawn and sweep taken from
`ThreadService+Judge`). P9 can put Codex behind the same function (answer file, capacity retry as `pr-review`
does) and add `agents.plan` next to `agents.goal`, with no change to what is below it. The judge and the describe
turn are **not** moved onto it in this phase.

## Config and command

```toml
# plan_model = "opus"       # --model for the plan turn; `plan --model` wins; unset = model
```

`workbench plan [id] [--model M] [--budget USD] [--again]`, once per approved goal unless `--again`.
`workbench plan show [id]` prints the latest plan, whether it was generated or edited, and what it cost.
`workbench plan edit [id]` writes the draft to change; `plan edit --apply` records the draft, and `plan edit --from
<file>` takes the text from a file, for scripts and for a plan written elsewhere (a different model, say). `workbench run [--no-plan]`. `status` and
`review` show "planned (opus, $0.21)" or "no plan"; the thread's cost line includes the plan's cost, itemised.

## Events

`plan.started` (`argv` without the prompt, `base_commit`, `goal_hash`) and `plan.ended` (`ok`, `reason`,
`cost_usd`, `duration_ms`, `plan_ref`, `sha256`, `bytes`, `truncated`, and `base_commit` and `goal_hash` again, so
the end record can be validated alone and a reader never has to join the pair). Neither is a turn, so `turns` and the work
session are unchanged. A hand edit is one event, `plan.edited` (`plan_ref`, `sha256`, `bytes`, `truncated`, `from_sha256`, `base_commit`,
`goal_hash`), written by `workbench plan edit` while it holds the log. `run`'s first `turn.started` gains `plan: {sha256, bytes, source}` (`generated` or `edited`) or `null`, so a run says whether
it had a plan. Spec in `docs/spec/event-log.md`, `--json` keys added never renamed.

## Tasks

| Task | Result | Gate |
|---|---|---|
| 1. Config, events, state | `plan_model`; `plan.started`/`plan.ended`; `ThreadState` derives "planned"; spec updated | config, event and state tests, including a log with a `plan.started` and no end |
| 2. The turn | `ReadOnlyAgent` (Claude), the base-commit checkout, `workbench plan`, sweep, holder marker, recovery | fake-claude tests for every failure below |
| 3. Into the run | `PromptBuilder.firstPrompt` takes a plan; stale-hash rule; `run --no-plan`; `turn.started.plan` | prompt snapshot tests; a changed goal means no injection |
| 4. Show and edit | `plan show`, `plan edit` (`--from`), `plan.edited`, `status`, `review`, cost line | CLI and `--json` fixtures; an edit becomes the plan the next run uses |
| 5. verify-cli | `scripts/verify-cli/plan.sh`: real `claude`, a throwaway thread, plan then run, using only workbench commands | a recorded PASS on this repository |
| 6. Compare | the same three goals, each run: no plan on Sonnet, no plan on Opus, Opus plan then Sonnet; cost, turns to a green check, judge verdict | numbers in this file; then decide the default |

One pull request each for tasks 1 and 2 (events and state are of no use without the turn that writes them), 3 and 4
(the plan reaches the run, and you can see and change it), and 5. Task 6 is a measurement and updates this file.

## Failure cases to test

Hangs; crashes; ignores SIGTERM; leaves a child behind, also detached; killed mid-run; stop before start; goal
unapproved; goal edited after approval; goal edited after the plan (stale, not injected); base commit missing;
checkout cannot be made or removed; `claude` missing; budget stop; empty answer; plan over 16 KB; an answer with a
credential or a machine path in it; the argv contains no `Bash`, `Edit` or `Write`; a second plan, a judge or a run
while one runs; `run --no-plan`; `plan --again` replaces which plan the next run uses; an edit then a regenerate (the regenerated one is latest); an edit
that is empty, unchanged, over 16 KB, or made after the goal changed; `$EDITOR` unset or failing; `plan edit` while a
run or a plan is running.

## Open questions

- **A gate later?** v1 has no approval step: the goal is already approved, the plan cannot change it, and the check,
  judge and review still follow. If task 6 shows bad plans are common and costly, an opt-in `plan_approval = true`
  (the run refuses until `plan approve`, bound to the plan's hash) is the likely answer, off by default.
- **Does it pay for itself?** Task 6 decides. A planner that costs more than the retries it saves should not be
  the default, and the answer may differ for a one-file fix and a cross-cutting change.
- **A different planner.** Whether another provider's model plans better is P9's `agents.plan`; the seam above is
  what makes that a config change. Compare on the same three goals before choosing.
- **Pipeline (P11).** Whether `plan` is a step of the verified pipeline, and what a failed check does to the plan,
  is decided there.
