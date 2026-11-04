# UI audit: what is hand-copied instead of a component

A read-only audit of `Sources/WorkbenchApp` (about 10,500 lines) as of the merge of #394, which turned the two button styles into one
`WorkbenchButtonStyle(kind:size:)` and made `scripts/check-banned-apis.sh` refuse a second button look. Buttons were the easy case. This
lists the same problem everywhere else, so the next PRs have a worklist. It ended as a plain ban (`scripts/check-ui-tokens.sh`).

The rule it is measured against (in `AGENTS.md`, Conventions): **anything visible that repeats is one component in
one file, with its variations as props (`kind`, `size`, `tone`, state); a new variant is a new case, never a copy; search before writing a
view.** Measurements (radius, padding, type size, tint strength) are tokens in `Theme`, not literals in a view.

Method: grep for the recipes below, then read each hit. Line numbers are from `main` at the time of writing and will drift; the file is
the thing to look at.

## Numbers (at the start of the audit)

| What | Count | Where it should live |
|---|---|---|
| `cornerRadius: <number>` | 45 in 16 files, 7 different radii (6, 7, 8, 10, 12, 14, 18) | a `Radius` token set; surfaces take it from a component |
| `.font(.system(size: <literal>)`, outside `ButtonStyles.swift` | 8, all in `RunSettingsInspector.swift` | text styles in `Theme` (or system text styles) |
| `.padding(<number>)` and `.padding(.edge, <number>)` | 163 | spacing tokens, mostly inside components |
| tint strengths for a tinted fill | 0.04, 0.08, 0.1, 0.12, 0.14, 0.2 | one per role |
| `Capsule()` | 12 in 6 views | one `Pill` |
| caps section labels | 6 sites, 3 variants | one `SectionLabel` |
| `struct …: View` | about 80 | |

## Findings, biggest first

### 1. The card: panel fill, radius 12, line stroke (7 copies)

`Theme.panel` + `RoundedRectangle(cornerRadius: 12)` + `.stroke(Theme.line)`, written out each time:
`ChatScreen.swift:178`, `DraftGoalCard.swift:130`, `FeedDecisionCard.swift:53`, `FeedRow.swift:416` (the goal card),
`NewThreadScreen.swift:207`, `RunCard.swift:134` (it also clips), `TaskPageView.swift:138` (its stroke changes with state).
Two more cards are the same idea with different numbers: `OverlayCard.swift:27` (radius 18, `controlBackgroundColor`, 0.1 white stroke)
and `ProjectPickerCard.swift:46` (radius 14, the same colours). Three radii and two fill colours for "a card".

**Component:** `Card(style: .panel | .overlay, stroke: .line | .tone(Color), clips: Bool) { content }`. One radius per style, from `Radius`.

### 2. The tinted note box: a tone at low opacity, radius 8 (7 copies)

`FeedRow.swift:205`, `MenuBarView.swift:150`, `ProjectPickerCard.swift:95`, `RootView.swift:178`, `TasksView.swift:124` and `:193`,
`TaskCards.swift:44`. Fill strength is 0.08, 0.1, 0.12 or `.quaternary.opacity(0.5)` for what reads as the same thing.

**Component:** `Callout(tone: Tone, content)`, with `Theme.color(for:)` choosing the colour and one strength. `.quaternary` ones become the
`.neutral` tone.

### 3. The outlined box: grey stroke at 0.4, radius 8 (3 copies)

`FeedDecisionCard.swift:69`, `FeedRow.swift:465`, `RootView.swift:139` (conditional). Likely the `Callout` with `outlined: true`.

### 4. Pills and chips (12 `Capsule()`, 4 components)

A tinted pill: `Badge` (`ProjectPickerCard.swift:207`, 0.12), `StatePill` (`RootView.swift:100`, 0.12), `KindChip` (`GoalFields.swift:154`, 0.14),
plus inline copies at `DraftGoalCard.swift:115` (0.14), `MenuBarView.swift:58` (0.14), `RootView.swift:61` (0.12). An outlined pill:
`Chip` (`RunSettingsChips.swift:4`) and an inline copy at `DraftGoalCard.swift:69`. The 0.12 vs 0.14 is not a decision, it is drift.

**Component:** `Pill(tone:, style: .tinted | .outlined, size:)`. `Badge`, `StatePill`, `KindChip` and `Chip` become call sites of it (or
thin wrappers that only decide the text).

### 5. Section labels in caps (6 copies, 3 variants)

`Text("NEXT")`, `"GOAL"`, `"DRAFT GOAL"`, `"DENIED CALLS"`, `"INSTRUCTIONS"`: `FeedDecisionCard.swift:61`, `FeedRow.swift:160` and `:460`,
`DraftGoalCard.swift:113`, `SendBackGrants.swift:47`, `TaskCards.swift:39`. `.caption` vs `.caption2`, tracking 0, 0.6 or 0.9.
`FeedRow.swift:160` and `:460` are the same label twice in one file.

**Component:** `SectionLabel(_ text)`, one style.

### 6. Rows with a symbol, a title and a detail (done: `IconRow`)

`FeedLine` (`FeedRow.swift`), `ToolGroupRow`, `PendingStepRow` and `MessageRow` each wrote the same leading symbol in a 16 wide column, an
8 pt gap and the first-text-baseline alignment. They now sit on `IconRow(symbol:tint:) { content }`; what follows the symbol is theirs.
The criteria list (`c1` in a 28 wide column) and the task settings (a 70 wide label column) are label-and-value rows, not symbol rows:
a different component if a third appears, not forced into this one.

### 7. Message rows (concluded: different by design, no change)

The chat's user bubble (`ChatMessageRow`: raised fill, uneven corners, 14/4) and the feed's `UserNoteRow` ("You · sent back": a quiet
`.quaternary` well, radius 10) look alike in a list of rows but are two designs for two situations, and the agent's text is not a bubble at
all. Merging them would change a design, not remove a copy.

### 8. Surfaces at radius 6 and 7 that are really buttons or thumbnails (done: `ButtonKind.icon`, `.thumbnail()`)

The three icon buttons (composer Send 30, composer "+" 26, rail "+" 24) are `.iconButton(size:)`, a kind of `WorkbenchButtonStyle`; the two thumbnails are `.thumbnail(outlined:)`; `Radius.control` (7) and `Radius.thumbnail` (6) name the numbers.


`ChatScreen.swift:133`, `NewThreadScreen.swift:183`, `PreviewRail.swift:21`: a raised, stroked rounded rect around a label or icon (radius 7 is
`WorkbenchButtonStyle`'s radius). They are almost certainly icon buttons: a `ButtonKind.icon` (or `.plain` at `.small`) instead.
Thumbnails at radius 6 (`NewThreadScreen.swift:247`, `RunCard.swift:273`) are one `Thumbnail` component.

### 9. Type sizes outside the text styles (done)

The inspector's eight hand-set sizes are system text styles now (`.body`, `.subheadline`, monospaced `.caption`); each moved by at most half a point. A raw `.font(` is now banned.


All 8 are `RunSettingsInspector.swift` (10.5, 11, 11.5, 13 and 13 semibold, by hand). The rest of the app uses `.callout`, `.caption` and
friends. The inspector should too, or `Theme` should name the two it needs.

### 10. Spacing (done: the `Space` scale)

Every padding and stack gap is a step of `Space` on a 4 pt grid (2, 4, 8, 12, 16, 20, 24, 32, 40, 48). The app had 32 distinct values (6, 10
and 14 were the common off-grid ones); each moved to the nearest step, a tie going up (so 6 became 8, 10 became 12, 14 became 16, 28 became
32), with no case-by-case judgement, so the change is one rule applied mechanically. `Spacing.gutter` (32) and `Spacing.inset` (16) are
aliases of steps. The check bans a number in `.padding(` and `spacing:`.

## What is already right

- `WorkbenchButtonStyle` (kind and size as props), `PlaceholderTextEditor`, `FeedLine`, `Theme` for colour (no `Color(red:)` outside it).
- `OverlayCard` as a layer, though it hand-writes its own surface (finding 1).

## Order of work

Each is one PR, each shows before and after shots of the screens it touches, each lowers the baseline above.

1. **`Radius` and `Card` (1).** Biggest and the least ambiguous: 7 copies, 3 radii. Add the numbers to `Theme`.
2. **`Callout` (2, 3).**
3. **`Pill` (4)** and **`SectionLabel` (5)**: small, and they fix visible drift (0.12 against 0.14, caption against caption2).
4. **Rows and messages (6, 7)**, after reading each; may turn out to be fewer.
5. **Icon buttons and `Thumbnail` (8)**, the inspector's type sizes (9).
The rule already exists, so the number cannot grow while this list is worked through:

- `AGENTS.md`, Conventions: a look that appears twice is a component with props.
- `scripts/check-ui-tokens.sh` bans the literals in the table above (radius, `.font(`, `Capsule()`, a number in `.padding(` or `spacing:`)
  outside the component files, and names the offender. It started as a ratchet with a baseline; once every count reached 0 the baseline
  had nothing left to say, so it became a plain ban (no baseline file, no `--update`). CI and `scripts/check.sh` run it and
  `scripts/test-ui-tokens.sh` tests it. A component file goes into its `COMPONENTS` list in the PR that adds it.
- A line in `pr-review` and `design-review`, "does a new view duplicate an existing component?", for what a count cannot see.

## Not decided here

- Whether `Card`, `Callout` and `Pill` take a `Tone` (the five state colours) or a `Color`. Tone is the safer default: the design says colour
  carries meaning, and a `Color` parameter lets a view invent a sixth.
- Whether the tokens are enums on `Theme` or a separate `Metrics.swift`. `Theme.swift` is colour today.

## Second sweep: text is a token

After the ten items above, a grep for what still repeats found the same `.font(...).foregroundStyle(...)` pair about 100 times, and 146
`.font(` calls in all, using about 18 distinct fonts. They are a closed scale now: `TextStyle` (the steps) and `TextTone` (the colours),
set with `.textStyle(style, tone)`; `TextRole` (`caption`, `detail`, `error`, `warning`, `mono`, `monoDetail`) is named combinations of the
two that recur. `micro` and `microStrong` drew exactly the same as `captionMedium` and `captionStrong`, so the scale has one of each.

The check bans any `.font(` outside the component files: a view does not set a font. A step the
scale lacks is a new `TextStyle` case, decided once.

Looked at and left: the 19 `Divider()`s are the system divider and need nothing; `Toggle` rows (the inspector's two) and the criteria and
settings label-and-value rows are two or three each, below the point where a component pays for itself.
