# P15: Agent ergonomics and test-backed criteria

Status: tasks 1, 1b, 2 and 3 built; the rest is plan. Written 2026-10-18 from the Triage pilot's third thread (FRICTION rows 65 and 66, and rows 8 and 56
seen again). Tasks 1 to 3 are small and independent; task 4 is planned and deliberately not scheduled.

## Why

Three things got in the way of a run driven by an agent:

1. `doctor` refuses once a goal is approved, so the environment cannot be checked between `goal approve` and `run`.
2. `workbench <command> --help` fails with "unexpected argument". The only help is one global usage block.
3. `review` lists criteria as "you check" whose proofs name tests that the project check ran and passed
   (`everythingOrder…`), so "1 passed, 5 to check" undercounts what Workbench verified.

## Order

One PR each, in this order. Each has its own goal file before code.

| Task | Result | Gate |
|---|---|---|
| 1. `doctor` after approve | `doctor` refuses only while a turn or a check is live in the project, not for any active thread. Its worktree is its own, so a draft or approved goal does not conflict. The refusal names the live turn. The one-active-thread rule and `ProjectLock` (doctor holds it, `create` drops it) are unchanged | tests: doctor with a draft goal, with an approved goal, with a live turn (refused, says which), with a finished turn, `goal new` while doctor runs (still refused), two doctors |
| 1b. verify-cli scenario for doctor **(built)** | `scripts/verify-cli/doctor.sh`: doctor passes with the goal approved and no turn and leaves the thread alone; is refused (exit 6, thread named) while a real turn is live; passes after it. Recorded 2026-10-18: PASS in 14 steps, about $0 (the turn is stopped early); with `VERIFY_CLI_SABOTAGE=1` exactly the two live-turn steps FAIL, exit 1 | the script, run by hand |
| 2. Per-command help **(built)** | `workbench <cmd> --help`, `-h` and `workbench help <cmd>` print that command's entries from the usage block (cut from it, so written once), then `changes:`, `example:`, `--json:` and `exit:` lines, exit 0, before any project is loaded. A usage error keeps its one stderr line and ends with the command's synopsis and `(workbench help <cmd>)`. One small table holds the added text | the verify-cli scenario `help.sh` (17 steps, no turn, so it costs nothing; the `VERIFY_CLI_SABOTAGE=1` run fails exactly the same-text step); tests: every command answers all three forms identically, multi-form selection, nothing written, usage errors in text and JSON, an unknown command, an option's value that reads `--help` |
| 3. A criterion backed by the tests the check ran **(built)** | The check run records which tests it saw pass (parsed from the runner's output, `swift test` first, behind one small parser type). `review` marks a criterion `passed` when its proof names a test that is in that list, from the latest turn's check, with the note "named test ran in the check, turn N". A named test that is absent stays "you check"; one that failed is `failed`; a prefix that matches several tests passes only if all of them passed. The free-text matching sits in its own function, commented as the fallback for proofs that are not typed. Built as `TestOutputParser` (fed line by line while the check runs, so the 1 MiB output cut does not matter) and `TestProof`. The Swift Testing output carries no suite, so only the name is compared | the verify-cli scenario `criteria-tests.sh`; tests: named test passed, absent, failed, a prefix matching two with one failing, a check from an earlier turn, no check, a runner format the parser does not know (stays "you check"), a proof that names the check itself (unchanged) |
| 4. Typed proofs (later) | See below. Not scheduled | — |

Task 3 also changes the `goal` skill to write a named-test proof in one shape (`proof: test: <Suite>/<name>`), so
the matcher is exact for new goals and only guesses for old ones.

## Task 4: typed proofs, planned and left for later

What is already built from [`later/proof.md`](../later/proof.md): `screenshot:` proofs, `verify_command`, the
`judge` as the advisory verifier, the `see screenshot` and `✘ missing` states. What is left is the typed
`check:`, `test:` and `diff:` proofs.

Why it waits: task 3 removes the symptom, and the open design question has a cost. Does a `check:` proof run its
own command, or only count when the project check already ran it? Running its own conflicts with "no concurrent
checks" and with one check per turn.

Shape when it is picked up, 2 to 3 PRs:

1. **Parser.** `proof: test: …`, `check: …`, `diff` are parsed into a `Proof` value; a free-text proof stays valid
   and reads as `manual`. `goal approve` rejects a typed proof nothing could produce, as it does for a screenshot
   with no `verify_command`.
2. **Evidence.** `test:` reads the test list task 3 records (the parser is reused, the free-text matcher is
   reduced to the legacy path). `check:` is matched against recorded checks, not run again, unless the design
   question is decided otherwise.
3. **Review and spec.** One row per criterion with its evidence and exit code; `docs/spec/goal-file.md` updated.

What task 3 leaves in place for it: the recorded test list, the output parser, and the `passed` note. What it
replaces: the free-text name matching.

Pick it up when a criterion needs `check:` or `diff:` evidence that task 3 cannot give, not before.

## Out of scope

- Making `diff` proofs verified. "A person reads the diff" is correctly "you check"; `judge` advises beside it.
- Test runners other than `swift test` in task 3. The parser has one seam for another.
- Any change to how `ship` or the judge read criteria.

## Acceptance

- [ ] `doctor` runs with a draft or approved goal and no live turn, and reports the environment.
- [ ] Every command answers `--help` with its own text, and exits 0.
- [ ] A criterion naming a test the check ran and passed in the latest turn is `passed` with its source shown;
      one naming a test that did not appear stays "you check".
- [ ] FRICTION rows 65, 66 and 56 are closed; row 8 stays open and points at task 4.
