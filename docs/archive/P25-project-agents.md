# P25: Project agents

Status: built (slices 1, 2 and 3). A project's `[agents.<role>]` tables decide who chats, drafts, plans, codes, judges, reviews
and writes the PR, and until now the only way to see or change them was the config file: a chat ran on Codex through `agents.goal` and
nothing in the app said so. This phase shows the setup, then lets a person change it.

## Slices

| Slice | What | Core change |
|---|---|---|
| 1 | The **Agents card** (read-only) and the agent named on a chat and on the new-thread screen | `AgentSetup`, a value read from `Config` through the resolvers a run uses; nothing is written |
| 2 (built) | `workbench config set <key> <value>` and `config unset <key>`, and the core editor behind them (`ConfigEdit`): one key changed, the file's comments and table order kept, the result parsed as a config before it is written, a change made meanwhile not overwritten; allowed while a thread is active (a chat is itself an active thread, and approval already refuses a run whose settings changed, so the command says so instead of blocking) | `ConfigEdit`; `GoalAgentSetup` now calls it; `scripts/verify-cli/config-set.sh` |
| 3 (built) | Pickers in the card (provider, effort and a model field per role; the goal agent can be turned off) that call `ConfigEdit`, and a warning with a one-tap `Use default model` when a model name looks like the other provider's | `AgentSetup.modelFit`, `AgentSetup.runChangeNote`; the app's `ProjectStore.setAgent` |

## Slice 1

- `AgentSetup` (`Sources/WorkbenchCore/Config/AgentSetup.swift`): one row per role in the order goal, plan, run, judge, review, ship, verifier.
  A row has the provider, the model (nil is the provider's own), the effort and where it came from: `configured` (the table names
  something), `providerDefault` (it names nothing, so the default runs) or `off` (no `[agents.goal]`, so chat and drafting are refused; or
  `[verifier] enabled = false`). It reads `resolvedGoalAgent`, `resolvedPlanAgent` and the other resolvers, so it shows what a command would run.
- The card is project-level, not part of the Run settings inspector: that one is per thread and writes the goal file. It opens from the agents pill in the
  top bar (it names the run role's provider and model) or Agents… in the app menu (⌘,), and closes with Esc, the close button or a click outside.
- A chat's footer and the new-thread screen name the goal agent (`Codex · gpt-6.1-terra`), or say that none is set.
- Reading writes nothing; a config that does not load shows "could not be read" and the Doctor says why.

Not in slice 1: changing a role, the machine-level `~/.workbench/config.toml`, per-goal model, budget and timeout (they stay in the inspector).

## Slice 2

`ConfigEdit.set` and `unset` take an `agents.<role>.<provider|model|reasoning_effort>` key and a plain-name value (letters, digits and
`. _ : / @ [ ] -`, up to 100 characters, so nothing needs escaping). The file is read once, edited as lines (a changed line keeps its indent and
trailing comment; a new key goes after the table's last line of content; a missing table is appended; `unset` removes the key and the table
when it was the last key and nothing else is in it), parsed with `Config.parse` and only then written, atomically and with the file's mode. A
config that does not load as it is, one over 256 KiB, or one with Windows line endings is refused untouched. Other keys (`check_command`,
`[tools]`, `allow_unpriced`, review stages) are not editable here.

## Slice 3

The card's rows are editable (`AgentRow` with an `AgentEdit`): a provider picker, an effort picker and a model field per role, each change one `ConfigEdit`
call off the main thread (`ProjectStore.setAgent`; the goal agent off removes its provider, model and effort together, since a goal table needs a provider),
followed by a fresh read of the config, so the card always shows what the file has and a refusal (a value the config would not load, no config file) is said in
words. The model is a typed name: no list of known models is kept, since it would go stale. `AgentSetup.modelFit` flags only names it knows (`opus`, `sonnet`,
`haiku`, `claude-*` on Codex; `gpt-*` and the o-series on Claude) and a provider change never clears the model silently. The verifier's model is read-only.

Added by the review of slice 3: `ConfigEdit.removeRole` takes a whole `[agents.<role>]` table out in one write (the goal agent off: a goal table needs a provider, so
its keys cannot go one at a time, and keys the card does not show, such as `allow_unpriced`, go with it); the card's edits run through one queue, in the order they were
made; and a role that `[review.stage.pr-review]` decides is shown read-only with the stage's name (editing `[agents.review]` would change nothing).

Next, as its own PR: a model menu per provider (Claude's aliases, the models any role in the config already names, and an optional `models = [...]` in `[providers.<id>]`, plus `Other…`).

## Model menu

The model of a role is chosen from a menu in the card: `Default model`, the names of the role's provider, `Other…` (which shows the text field). The names are, in this
order and without repeats: `ModelCatalog` (`Sources/WorkbenchCore/Config/ModelCatalog.swift`, the one file to update when a provider's models change: Claude's aliases `opus`,
`sonnet`, `haiku`, which follow its latest and do not go stale, and the Codex models its CLI lists as visible, rewritten from the installed CLI by `scripts/update-model-catalog.sh`,
`--check` to see whether the file is behind), then the project's `[providers.<id>] models = [...]`, then the models any role of that provider already uses (a `pr-review` stage's
included), so what a project set never drops out of its own menu. Nothing is fetched while the app runs and nothing checks that a chosen model exists: `Other…` is never refused
for being unknown. The catalog is a Swift file, not a resource read at runtime, so it needs no bundle in the package, the CLI or `bundle-app.sh`.

