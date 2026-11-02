# Xcode 27.2 (Swift 6.4.2): the `Simplification` pass aborts a release build

`swift build -c release` (the app, the CLI, or `--target WorkbenchCore`) stops with

```
SIL/BorrowUtils.swift:551: Fatal error: cannot get borrow introducers for unknown guaranteed value
While running pass SILFunctionTransform "Simplification" on SILFunction "...ThreadService...planLocked..."
```

It happens on `origin/main` too, so it is the compiler, not a change. Debug builds and the tests are fine. CI builds with Xcode 26.1
(Swift 6.2.1), which does not have it.

What was tried, each on `ThreadService.planLocked` (`Sources/WorkbenchCore/Thread/Plan/ThreadService+Plan.swift`), none of which
avoided it: moving the agent turn into its own function, choosing the agent with one expression instead of a deferred `let`, making
`attach` `@escaping`, `@inline(never)`. Cutting the function short made the crash move to `plan`, which calls it inside the `withLog`
closure, so no single construct is to blame.

What works: `-Xllvm -sil-disable-pass=simplification`, in `Package.swift` next to the `simplify-cfg` workaround. The core library, the CLI
and the app then build in release on Xcode 27.2.

To see whether it is still needed: take `-sil-disable-pass=simplification` out of `simplifyCFGWorkaround` and run
`swift build -c release --target WorkbenchCore` on the newest Xcode. If it compiles, remove the flag for good. A report to Apple
(Feedback Assistant) with a reduced case would be the real fix; there is no small case yet.
