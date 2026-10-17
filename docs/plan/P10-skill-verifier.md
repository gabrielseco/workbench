# P10: A verifier that runs the project's skill

Status: plan, nothing built. Written 2026-10-17. Friction row 57. Builds on [P4](P4-verify.md) (`verify_command`,
proof, the judge), [P6](P6-review-stages.md) (reading a skill file as instructions) and the project-instructions
loader (a file read from the base commit). [P9](P9-agent-providers.md) will decide which providers can run it. 
[P11](P11-verified-pipeline.md) runs it as the `verify` step of a pipeline, before `ship`, with the proof tied to a commit.

## Why

A thread's proof can show the app at launch (`verify_command`) and, with a recipe file in the repo, in one chosen
state (Triage's `scripts/verify-steps/`, #65). That needs a file per screenshot, a thread can edit it, and the only
guard is a list of refused button names. The project already has the real thing in a skill: Triage's `/verify`
builds the change, drives the app to the state each claim needs, looks, and says whether it shows. The owner uses
skills like that in other repos and wants Workbench to run it, not to replace it with scripts.

Workbench cannot run it as it is: a run starts in safe mode, which removes skills, and the skill itself tells the
model to `pkill` and `open` the app, which can hit the installed one. Its guards are prose.

## The idea

After a turn's check and verify, Workbench can run a **verifier turn**: a separate `claude -p` run, not the coding
run, whose instructions are the project's skill file **read from the base commit**, with a tool list the project
sets in its config. It drives the app, takes the screenshots the goal names, and ends with a short report. The
judge then reads the proof as it does today. It is advisory and never gates `accept` or `ship`.

|  | judge (built) | verifier (this plan) |
|---|---|---|
| Instructions | built-in prompt | the project's skill text at the base commit |
| Tools | none, or `Read` on the screenshots | the project's `[verifier] tools`, e.g. `bash` helpers and `Read` |
| Produces | a verdict per criterion | screenshots of the states the criteria need, and a report |
| Mode | `--safe-mode`, `--restricted` | `--safe-mode`, `--restricted`, `--disable-slash-commands` |

## Rules

1. **Instructions come from the base commit**, never the worktree, capped in size with a marker where it is cut,
   with its path, size and sha256 recorded. The coding run can edit `.claude/skills/`; it cannot change what its own
   verifier is told.
2. **The tools are the project's config, not the skill's front matter.** `[verifier] tools` is a list of Claude
   Code permission patterns. A bare `Bash` or `Bash(*)` is refused at config load, and `doctor` prints the list.
   The skill's own `allowed-tools` (which includes `pkill` and `open`) is not read.
3. **Safe mode stays on.** No hooks, plugins or MCP, and slash commands are off: the skill is text in the prompt.
4. **Own session, budget and time.** Defaults $1.00 and 10 minutes, once per turn unless `--again`, the thread's
   log held while it runs (a second one is `busy`), as for the judge.
5. **Everything it starts is swept, on every ending.** It runs under `Spawner` in its own process group and
   `OrphanSweeper` ends what is left: stop, timeout, crash, restart. The app must be a child of the run (launched
   directly), not started through LaunchServices, or the sweep cannot see it.
6. **A turn always ends.** `verifier.started` is followed by exactly one `verifier.ended`, also on stop, timeout,
   crash and restart recovery.
7. **Same environment contract as verify**: `WORKBENCH_PROOF_DIR`, `WORKBENCH_THREAD`, `WORKBENCH_GOAL`, on the
   allowlisted environment (`env_pass`). Screenshots are named by the goal's `proof: screenshot: <name>`.
8. **Its words are never a pass.** The report is stored bounded and shown by `review` as a note; a screenshot is
   still something a person looks at.
9. **The project owns its safety helpers.** Workbench does not know `ax.swift`. Triage's helpers keep their
   refusal list and PID targeting; the tool list decides which helpers the model may run at all.

## Config

```toml
[verifier]
skill = ".claude/skills/verify/SKILL.md"    # instructions, read from the base commit
tools = ["Read", "Bash(scripts/verify-app.sh:*)", "Bash(scripts/snap.sh:*)", "Bash(swift scripts/ax.swift:*)"]
budget_usd = 1.00
timeout_min = 10
```

No `[verifier]` table means today's behaviour. A skill file that is missing or empty at the base is a refusal with
the path, never a verifier that runs without instructions.

## Events and command

`verifier.started` (`argv` without the prompt, `skill`, `sha256`, `bytes`) and `verifier.ended` (`ok`, `reason`,
`cost_usd`, `duration_ms`, `files`, `report` bounded), and the existing `proof.added` for each PNG it leaves.
`workbench verifier [id] [--again]` runs it by hand, as `judge` does; running it automatically after verify is an
open question below. Spec in `docs/spec/event-log.md`, `--json` keys added never renamed.

## The Triage side

Not a rewrite of the skill, and not a second system: a small helper and a short section in the skill.

- `scripts/verify-app.sh` takes the part of `verify.sh` that makes the throwaway build safe to launch (its own
  bundle id, signing, a copy of three settings) and prints the PID and window id, so `verify.sh` and the skill share
  it. Without it the skill's own build has the installed app's bundle id and opens no window.
- `/verify` gets an "under Workbench" section: build with `TRIAGE_APP`, launch through the helper (the binary, never
  `open`), drive with `TRIAGE_PID` set, save screenshots to `$WORKBENCH_PROOF_DIR`, never touch the installed app.

## Tasks

| Task | Result | Gate |
|---|---|---|
| 1. Config and `doctor` | `[verifier]` parses; a bare `Bash` is refused; `doctor` reads the skill at the base and prints the tools | config and doctor tests, including a missing and an oversized skill |
| 2. The turn | `workbench verifier`: argv, prompt (skill text, goal criteria, environment), bounded run, sweep, events | fake-claude tests for every failure below |
| 3. Proof and review | PNGs recorded as proof; `review` shows the verifier's note; the judge reads them | `review` fixtures; a screenshot criterion satisfied by the verifier's file |
| 4. Triage pilot | `verify-app.sh`, the skill's section, the Bot finding criterion from Triage #66 including the half the recipe could not show (a finding on someone else's PR has no fix buttons) | a recorded run with screenshots of both states |
| 5. Compare | the same criterion five times with the recipe and with the verifier: cost, time, how often the screenshot shows the state | numbers in this file; then decide whether the recipe files go |

## Failure cases to test

Hangs; crashes; ignores SIGTERM; leaves the app running, also detached; killed mid-run; stop before start; skill
missing at the base; skill over the size limit; an invalid or bare-`Bash` tool pattern; budget stop; the app's
window never appears; a refused press (the helper exits 1 and the model is told); a second verifier while one runs.

## Open questions

- **Manual or automatic?** The judge is manual because it costs money. A verifier that runs after every verify is
  more useful and more expensive; `[verifier] auto = true` is the likely answer, off by default.
- **Where do its screenshots go?** The verify step's proof directory is per turn; the verifier would add to the same
  directory. A name that verify already wrote needs a rule (the verifier's wins, both recorded).
- **Providers.** It runs on Claude. Whether Codex can drive tools the same way belongs to P9.
- **Grants.** Verify under Workbench already captured the screen and pressed buttons from the owner's terminal. Check
  that the same holds for processes a `claude` run starts with its `Bash` tool.
