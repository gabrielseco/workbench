# P16: Run

Status: built for Workbench (this phase); the Triage and expense-tracker configs are their own pull requests. Written 2026-10-20.
Builds on [P10](P10-skill-verifier.md) (the verifier, the sweep, the environment contract).

## Why

The verifier has to drive the project's app, and each project hid how to start it inside a helper the model may run:
Triage's launches a throwaway bundle, expense-tracker's `shot.sh` picks a port, starts `npm run dev:mock`, waits for
it with `curl`, and kills it with `pkill` on every exit. That is the same job in two shell scripts, and it is the
part P10 worried about most: an app the model starts is an app Workbench has to find again to end. It also forces
the project to allow the launch to the model (expense-tracker denies `npm run dev:*` to the coding run, and could not
list it for the verifier without opening that).

## What it is not

Not `verify_command` back. P10 removed that key because it mixed two things: launching the app and judging it, and
because the script it named was in the worktree, which the coding run can edit. `[run]` is the first half only:
a command and a ready check, from the project's config (outside the worktree). Nothing it prints or returns is a
verdict; the verifier still drives, looks and reports, and a person still looks at the screenshots.

## The config

```toml
[run]
command = "npm run dev:mock"                # or "scripts/mock.sh"; one plain command, like check_command
ready_url = "http://localhost:{port}/"      # or ready_line = "Triage on mock data"; exactly one
ready_timeout_s = 120                       # 1 to 900
```

- `ready_url`: an `http` URL on this machine, `{port}` filled in; any HTTP answer is "up" (a 404 is a server).
- `ready_line`: a regular expression on the command's merged output. Triage's `mock.sh` prints a line just before it
  opens the app, which is the closest thing a desktop app has to a port.

## What happens

1. `verifier.started`, then `run.started` (`command`, `port`, the ready check).
2. Workbench picks a free port and starts the command in the worktree through `ProcessRunner`, on the allowlisted
   environment plus `WORKBENCH_PORT`, `PORT` (Next reads it), `WORKBENCH_THREAD`, `WORKBENCH_GOAL`.
3. It waits for the ready check, the command's exit, or `ready_timeout_s`. If the app ends first, never comes up or is
   not found: `run.ended` with the reason and the last 20 lines of output, then `verifier.ended` with the same reason.
   `claude` is never started, so nothing is spent.
4. Otherwise `claude` runs with `WORKBENCH_RUN_PID`, `WORKBENCH_PORT` and (for a URL) `WORKBENCH_RUN_URL` in its
   environment and prompt, and a paragraph telling it the app is already up and is not its to start or stop.
5. When `claude` ends, however it ended, the app and its whole tree are ended (SIGTERM, then SIGKILL after the grace)
   and `run.ended` is written. A `stop` during the wait reaches the app; a crashed runner leaves a `run.started` that
   the next command to open the log closes with a synthetic `run.ended` before the verifier's.

## Rules

1. One command per project; no restart-on-crash, nothing kept up between turns.
2. The app never outlives the turn: it has its own lifetime cap (verifier timeout + ready timeout + 30 s), and the
   orphan sweep that already covers the worktree covers it.
3. The config is the project's, read from the checkout, not from the worktree.
4. Launch only. No exit code or output of the app decides anything.

## Pilots

- Triage: `command = "scripts/mock.sh"`, `ready_line` on its "Triage on mock data" line. The helper the verifier may
  run keeps only the capture.
- expense-tracker: `command = "npm run dev:mock"`, `ready_url`. `shot.sh` keeps only the capture; the port, the wait
  and the `pkill` go.

## Later

`workbench run <thread>` to start a thread's app by hand (what `/verify` does today with a swap-in), and window-based
ready checks for desktop apps that print nothing.
