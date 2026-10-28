# Later

Deliberately not now. Each item is real, but building it before one thread works well is how the first
attempt went wrong. Nothing here is started until the "well" gate in the [plan](../plan/README.md) is met.
One exception: the [portability](portability.md) *probe* (trying one non-Swift repo and writing down what
breaks) comes after P2, before the app is designed. It builds nothing; fixing what it finds waits for the gate.

Optional agent-assisted goal drafting has moved into [P9](../plan/P9-agent-providers.md), with its own
provider/model selection and explicit human approval. It is no longer deferred until after the app.

Order of likely return, each decided on its own once the previous is used daily:

| Item | What it is | Notes |
|---|---|---|
| Concurrency | More than one active thread, one project | Lift the single-thread guard; add a thread list. Biggest new risk is shared process and CPU budget, resume races and CI-like contention; needs its own soak. The on-disk layout is already per-thread. |
| Many projects | A project list, a global store | Revisit D6 (data in `.workbench/` per repo). See [portability](portability.md). `workbench new` and the global defaults file are built ([spec](../spec/new-project.md)); a list and a global thread store are not. |
| [Portability](portability.md) | Other stacks: dependencies in a fresh worktree, secrets, hooks, toolchain env, per-repo checklists | Try one non-Swift repo after P2 and write down what breaks, before designing the app. |
| [Project setup](project-setup.md) | `workbench doctor`, a guided `init`, checks for small and large projects | The user declares the commands; Workbench only verifies them. No stack guessing. |
| [Proof](proof.md) | Typed evidence per criterion, screenshots, optional verifier | Advisory only, never a mandatory gate. |
| [Triage integration](triage-integration.md) | Start a thread from a PR, status badge | Only once Workbench is used daily. |
| [Thread list](thread-list.md) | Switch between a project's threads in the app | Needs concurrency: with one active thread the window already follows it, and `New goal…` appears once nothing is left to ship. |
| [Thread until merged](thread-until-merged.md) | A shipped thread stays open, watching its PR, until it is merged | Needs concurrency: it would hold the only active thread. Today `ship --watch` ends and `clean` removes merged threads. |
| Profiles | Several named tool sets | One fixed set until the first real need. |
