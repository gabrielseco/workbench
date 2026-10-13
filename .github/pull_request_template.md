<!-- Title: Conventional Commits, `type(scope): subject` (see AGENTS.md). A squash merge keeps it. -->

## Summary

<!-- What changes, in a few sentences. -->

## Why

<!-- The task or problem. Link the phase plan task if there is one. -->

## What changed

<details>
<summary>Files and behaviour</summary>

<!-- Per area, short. -->

</details>

## Testing

- [ ] `scripts/check.sh` passes
- [ ] New tests cover the failure cases the plan lists
- [ ] Soak run (`WORKBENCH_SOAK=1 swift test --filter SoakTests`), if the process or event-log layer changed
- [ ] Docs and spec updated, if behaviour changed
- [ ] Real `claude` run, if the invocation or stream handling changed
