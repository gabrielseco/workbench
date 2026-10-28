# Thread list

A list of a project's threads in the app, to switch between them (open an old one, compare, pick one back up).

**Why it waits.** The project has one active thread and no queue (see the [plan README](../plan/README.md)), so the app shows the
newest thread and `New goal…` appears once it is decided; for accepted or shipped work it is offered with a note naming the terminal command that still reaches the old thread, because there is no way back to it in the window. A list is only useful with more than one thread open at a time, which is
[concurrency](README.md) (its table row): the single-thread guard, the shared process and CPU budget, resume races. Until then a
finished thread is read from the window's banner and its log.

**What it needs when it comes.** `ThreadStore.summaries()` already lists every thread with its state; a row would carry the title, the
spine's current step and the attention mark the menu bar uses. Selecting one changes which thread the window follows
(`ProjectStore.currentThread`); nothing else in the window assumes a single thread except the active-thread guard in core.

Raised by the user while using the app on a real project (2026-10-28).
