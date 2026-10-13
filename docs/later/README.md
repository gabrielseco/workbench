# Later

Deliberately not now. Each item is real, but building it before one thread works well is how the first
attempt went wrong. Nothing here is started until the "well" gate in the [plan](../plan/README.md) is met.

Order of likely return, each decided on its own once the previous is used daily:

| Item | What it is | Notes |
|---|---|---|
| Concurrency | More than one active thread, one project | Lift the single-thread guard; add a thread list. Biggest new risk is shared process and CPU budget, resume races and CI-like contention; needs its own soak. The on-disk layout is already per-thread. |
| Many projects | A project list, a global store | Revisit D6 (data in `.workbench/` per repo). See [portability](portability.md). |
| [Portability](portability.md) | Other stacks: dependencies in a fresh worktree, secrets, hooks, toolchain env, per-repo checklists | Try one non-Swift repo after P2 and write down what breaks, before designing the app. |
| [Proof](proof.md) | Typed evidence per criterion, screenshots, optional verifier | Advisory only, never a mandatory gate. |
| [Triage integration](triage-integration.md) | Start a thread from a PR, status badge | Only once Workbench is used daily. |
| Goal drafting by Claude | A read-only turn that proposes the goal | You still approve. |
| Profiles | Several named tool sets | One fixed set until the first real need. |
