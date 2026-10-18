# P10: A verifier that runs the project's skill

Status: plan, nothing built. Written 2026-10-17, extended 2026-10-18 (design stage, model, skill location, PR breakdown). Friction row 57. Builds on [P4](P4-verify.md) (`verify_command`,
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

10. **The skill is an explicit path, never discovered.** Projects keep skills under `.claude/skills/` or `.agents/skills/`
    (this repo links the first to the second). `skill` names the file; both work. It must be a regular file at the base
    commit: git stores a symlink as its target path, so reading it would hand the model a path as its instructions. A
    symlink is refused with the real path to use.
11. **The model is the project's choice.** `[verifier] model` is passed as `--model`; unset it falls back to the coding
    `model`. Recommended: `sonnet`. The run is a long loop of short tool calls and screenshot reading, which Haiku
    is the likeliest to get wrong (a wasted run still costs money) and Opus adds little to, since the skill is written
    down. PR 5 measures it.
12. **Claude only.** The verifier runs tools (build, launch, press, capture), which the read-only Codex sandbox the
    review stages use forbids. A Codex verifier is a P9 question; the config has no `provider` key, so P9 adds one
    without renaming anything.

## Config

```toml
[verifier]
skill = ".claude/skills/verify/SKILL.md"    # instructions, read from the base commit; an explicit path, `.claude/` or `.agents/`
model = "sonnet"                            # --model for the verifier; unset = the coding model
tools = ["Read", "Bash(scripts/verify-app.sh:*)", "Bash(scripts/snap.sh:*)", "Bash(swift scripts/ax.swift:*)"]
budget_usd = 1.00
timeout_min = 10
```

No `[verifier]` table means today's behaviour. A skill file that is missing or empty at the base is a refusal with
the path, never a verifier that runs without instructions.

## What the design stage gets

`design-review` is Triage's skill: scope, a static pass over the diff, a capture matrix (dark mode, 1000×600 and
1600×1000, states, before from `origin/main`), a designer's review, a report posted on the PR. The shipped
`[review.stage.design]` runs only the judging half. It is a read-only Codex run over a brief (diff, goal, criteria,
`docs/DESIGN.md`, the skill as a rubric with a header saying to ignore the build, run and post steps) and the proof
images, and ends in `VERDICT: CLEAN` or `FIX`. It builds nothing, so it can only judge what is in `proof/`.

On Triage #75 (thread `g-2026-10-18-triage-everything-created-order`) it was handed one dark, launch-size
screenshot and said so: "Minimum-size and before screenshots were not supplied." Verdict `CLEAN`, in 24 seconds.

The verifier does not change the stage. It changes what the stage is handed:

| Part of `design-review` | Today | With the verifier |
|---|---|---|
| Rubric (hierarchy, type, color, states) | yes | yes |
| Static pass over the diff | possible, not required | possible, not required |
| Capture matrix, before/after | no | yes, for the states the goal names |
| Posting findings on the PR | no | no |

So a goal for a UI change names the captures it needs (`proof: screenshot: everything-order, everything-min-size,
everything-before`), the verifier takes them, and PR 3 makes the stage and the judge read every PNG in the turn's
proof directory, with its pixel size (row 10 of [P11](P11-verified-pipeline.md)). What the stage still cannot do is
press a button: a state nobody captured stays unreviewed.

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

## Tasks and pull requests

Five pull requests, four in this repo and one in Triage. Each ships alone with its own tests; PR 2 follows PR 1 at once,
since a config nobody can run proves nothing. Size is the diff a reviewer reads: S is a day, M two to three.

| PR | Repo | Result | Gate | Size |
|---|---|---|---|---|
| 1. Config and `doctor` | Workbench | `[verifier]` (`skill`, `tools`, `model`, `budget_usd`, `timeout_min`) parses; a bare `Bash` is refused; the skill is an explicit path (`.claude/` or `.agents/`) that must be a regular file at the base, a symlink is refused; `doctor` prints the path, model and tools | config, skill-reader and doctor tests, including missing, empty, oversized and symlink | S |
| 2. The turn | Workbench | `workbench verifier`: argv with `--model`, prompt (skill text, goal criteria, environment), bounded run, sweep, events; Claude only; the `verifier.sh` verify-cli scenario | fake-claude tests for every failure below; scenario PASS and sabotage FAIL | M |
| 3. Proof and review | Workbench | PNGs recorded as proof; `review` shows the verifier's note; a criterion can name several screenshots; the judge and the design stage get every PNG in the proof directory with its pixel size | `review` and review-stage fixtures; a screenshot criterion satisfied by the verifier's file | M |
| 4. Triage side | Triage | `verify-app.sh` and the skill's "under Workbench" section; `[verifier]` in Triage's config with `model = "sonnet"` | a recorded verifier run on the Bot finding criterion from Triage #66, including the half the recipe could not show (a finding on someone else's PR has no fix buttons) | S |
| 5. Pilot and compare | Workbench (docs) | #75's Everything order run with the verifier; the same criterion five times with the recipe and with the verifier, and the model as a variable (Sonnet against Haiku; Opus only if Sonnet fails): cost, time, how often the screenshot shows the state | numbers in this file; then decide whether the recipe files go and whether `[verifier] auto` is worth it | S |

Order: 1, 2, 3 in Workbench, then 4 in Triage, then 5. PR 3 can start once PR 2 has merged; PR 4 only needs PR 2.
Dropped from scope for now: `[verifier] auto`, and any provider but Claude (P9).

## Failure cases to test

Hangs; crashes; ignores SIGTERM; leaves the app running, also detached; killed mid-run; stop before start; skill
missing at the base; skill over the size limit; an invalid or bare-`Bash` tool pattern; budget stop; the app's
window never appears; a refused press (the helper exits 1 and the model is told); a second verifier while one runs.

## Open questions

- **Manual or automatic?** The judge is manual because it costs money. A verifier that runs after every verify is
  more useful and more expensive; `[verifier] auto = true` is the likely answer, off by default.
- **Where do its screenshots go?** The verify step's proof directory is per turn; the verifier would add to the same
  directory. A name that verify already wrote needs a rule (the verifier's wins, both recorded).
- **Providers.** Decided for now: Claude only (rule 12). Whether Codex can drive tools belongs to P9.
- **Which model?** Sonnet is the default recommendation (rule 11). PR 5 runs Sonnet against Haiku on the same
  criteria, Opus only if Sonnet fails; if Haiku shows the right state about as often at a third of the cost, switch.
- **Grants.** Verify under Workbench already captured the screen and pressed buttons from the owner's terminal. Check
  that the same holds for processes a `claude` run starts with its `Bash` tool.
