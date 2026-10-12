# P3: App

**Outcome:** one macOS window where you write a goal, approve it, watch Claude work, review the result and
decide. You complete a real task end to end without the terminal.

**Depends on:** P2 accepted. The app links `WorkbenchCore` and adds no process logic.

## Scope

In:
- One window, one project (chosen once, remembered), one current thread.
- Goal editor with draft/approved state and an explicit Approve button.
- Live view of a running turn, derived from the event log.
- Run, stop, send back, accept, discard.
- A short history of finished threads, read-only.
- Persistence: relaunch and the thread is where it was; a run that was in flight shows `interrupted`.

Out: project list, thread list with several active, multiple windows, notifications, menu bar, Triage,
screenshots and proof.

## Design

### Thread state machine

```
Draft ──approve──▶ Ready ──run──▶ Running ──▶ Review ──▶ Done
  ▲                  │              │  ▲        │
  └── edit goal ─────┘              │  └─ send back (follow-up turn)
                                    └─ stop / timeout / fail ─▶ Stopped | Failed  (can run again)
```

State is derived from the event log by the one pure function from P2, so the UI never stores a second copy
and crash recovery is free.

### What the live view shows

- Assistant text (streamed).
- Tool uses collapsed to one line (`Edit Sources/Sync.swift`, `Bash swift test`), expandable.
- Denied tool uses highlighted: they explain why a run stalled.
- Status bar: turn number, elapsed, cost so far, stop button.
- A "Raw log" disclosure that shows lines verbatim.

### Layout

```
┌ Goal  [Draft|Approved] [Approve] ──────────────────┐
│ Request / Criteria / Out of scope                  │
├ Activity (live) ───────────────────────────────────┤
│ …                                                  │
├ Review (after a turn) ─────────────────────────────┤
│ Diff · Checks · Criteria      [Accept][Send back…][Discard]
└────────────────────────────────────────────────────┘
```

A single column is enough. A sidebar comes back when there is more than one thing to put in it.

## Tasks

1. **App shell.** SwiftUI target, window, project picker (choose a git repo once).
2. **Store.** `@Observable` store over `WorkbenchCore`; subscribes to log appends; no process code in the app.
3. **Goal editor.** Plain text with live validation, Approve disabled until valid, editing an approved goal
   warns it returns to draft.
4. **Run controls.** Run, Stop, send back. All async, non-blocking.
5. **Live activity view.** Event grouping, streaming text, collapsed tools, denied highlighting.
6. **Review view.** Diff, checks, criteria, decision bar (from P2).
7. **Failure and empty states.** No project, no thread, goal invalid, run failed (reason shown), interrupted
   (offer re-run), `claude` not found.
8. **Polish.** ⌘N new thread, ⌘↩ approve/run, ⌘. stop. VoiceOver labels on icon buttons.

## Acceptance criteria

- [ ] From a clean install: pick a repo, write a goal, approve, run, watch, review, accept, with no terminal.
- [ ] Quit mid-run and relaunch: the thread shows `interrupted` with the log intact; re-run works.
- [ ] Stop returns the UI to a usable state in under 6 seconds, including with a stuck child.
- [ ] Editing an approved goal visibly returns it to draft and disables Run.
- [ ] No UI hitch while a turn streams 5k events (main thread never blocked > 50 ms).
- [ ] Every empty and error state in task 7 has a screenshot in the PR and reads as actionable.
- [ ] The app target contains no `Process`, no `Subprocess`, no shell strings (grep-enforced).
- [ ] The "20 real tasks" gate in the [plan README](README.md) is met by using this app.

## Risks

| Risk | Mitigation |
|---|---|
| UI state drifts from the log | One derive function; UI tests replay fixture logs |
| Streaming flood janks SwiftUI | Coalesce partial text updates (~30 Hz), virtualize the event list |
| Goal editing becomes its own project | Plain text editor + validation; richer editing only if it hurts |

## Demo

Create a thread for a small real task in a real repo, approve, watch it work, stop it half way, relaunch the
app, send a follow-up, review, accept.

## Open questions

- Should Claude draft the goal from a rough sentence (a read-only turn)? Leaning: later; P3 is you writing it.
