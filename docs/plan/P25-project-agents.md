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
- The card is project-level, not part of the Run settings inspector: that one is per thread and writes the goal file. It opens from an `Agents…`
  link in the rail under Scheduled (as `New task…` does) and closes with Esc, the close button or a click outside.
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
