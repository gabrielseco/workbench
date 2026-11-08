#!/bin/sh
# Process-layer lessons (docs/plan/P1-runner.md): these calls caused the hangs we are not repeating.
# Foundation's Process is banned too: children start through Spawner only (rule 8).
# Fails if any appear in code under Sources/. Comments may name them. A deliberate use needs a design
# discussion, not an exception here.
set -u
cd "${BANNED_APIS_ROOT:-$(dirname "$0")/..}"
status=0
for pattern in 'waitUntilExit' 'readDataToEndOfFile' 'Process()'; do
    hits=$(grep -rnF --include='*.swift' "$pattern" Sources | grep -Ev '^[^:]+:[0-9]+:[[:space:]]*//')
    if [ -n "$hits" ]; then
        echo "$hits"
        echo "error: banned API '$pattern' used in Sources/" >&2
        status=1
    fi
done
# Frameworks Linux does not have. The library and the CLI build there (the PR gate), and the macOS lint job cannot see a missing module:
# `import CryptoKit` passed it and failed only the Linux build (#366). Hashing is `SHA256` in WorkbenchCore (it has CryptoKit's shape);
# a macOS-only file in the app is guarded with `#if canImport(...)`, as the tests are.
hits=$(grep -rnE --include='*.swift' '^[[:space:]]*import[[:space:]]+CryptoKit' Sources | grep -Ev '^[^:]+:[0-9]+:[[:space:]]*//')
if [ -n "$hits" ]; then
    echo "$hits"
    echo "error: 'import CryptoKit' in Sources/: Linux has no such module; use SHA256 from WorkbenchCore" >&2
    status=1
fi
# The app (P19) starts nothing itself: it calls WorkbenchCore, which spawns through `Spawner`. Every way of starting a process
# or shell out of Swift is banned there, not only the three above.
for pattern in 'Process(' 'Subprocess' 'posix_spawn' 'NSTask' '/bin/sh' '/bin/bash' '/bin/zsh'; do
    hits=$(grep -rnF --include='*.swift' "$pattern" Sources/WorkbenchApp 2>/dev/null | grep -Ev '^[^:]+:[0-9]+:[[:space:]]*//')
    if [ -n "$hits" ]; then
        echo "$hits"
        echo "error: process API '$pattern' used in Sources/WorkbenchApp/" >&2
        status=1
    fi
done
# libc's `system(`, not SwiftUI's `.system(`: only a bare call.
hits=$(grep -rnE --include='*.swift' '(^|[^.A-Za-z0-9_])system\(' Sources/WorkbenchApp 2>/dev/null | grep -Ev '^[^:]+:[0-9]+:[[:space:]]*//')
if [ -n "$hits" ]; then
    echo "$hits"
    echo "error: process API 'system(' used in Sources/WorkbenchApp/" >&2
    status=1
fi
# The app's one multi-line text box is PlaceholderTextEditor: a bare TextEditor needs a hand-placed placeholder, which was off the line you
# type on three times. `PlaceholderTextEditor(` does not match: the pattern wants TextEditor( not preceded by a name character.
hits=$(grep -rnE --include='*.swift' '(^|[^A-Za-z0-9_])TextEditor\(' Sources/WorkbenchApp 2>/dev/null \
    | grep -Ev '^[^:]+:[0-9]+:[[:space:]]*//' | grep -v '^Sources/WorkbenchApp/PlaceholderTextEditor.swift:' || true)
if [ -n "$hits" ]; then
    echo "$hits"
    echo "error: 'TextEditor(' in Sources/WorkbenchApp/: use PlaceholderTextEditor (its placeholder is measured to sit on the line you type on;" >&2
    echo "       a hand-placed overlay was off three times). See AGENTS.md, Conventions." >&2
    status=1
fi
# Every button that looks like a button is `WorkbenchButtonStyle` (ButtonStyles.swift), reached through `.primaryButton(size:)` and
# `.plainButton(size:)`: kind and size are props, the radius, type and states live in that one file. The system `.bordered` is a second
# look for the same thing, and a `ButtonStyle` type declared anywhere else is a third. `.plain`, `.borderless` and `.link` stay: they are
# for icons, rows and links, which are not boxes.
hits=$(grep -rnE --include='*.swift' '\.buttonStyle\(\.bordered\)|:[[:space:]]*(Prominent)?ButtonStyle[[:space:]]*\{' Sources/WorkbenchApp 2>/dev/null \
    | grep -Ev '^[^:]+:[0-9]+:[[:space:]]*//' | grep -v '^Sources/WorkbenchApp/ButtonStyles.swift:' || true)
if [ -n "$hits" ]; then
    echo "$hits"
    echo "error: a second button look in Sources/WorkbenchApp/: use .primaryButton(size:) or .plainButton(size:); a new look or size is" >&2
    echo "       a new kind or size in ButtonStyles.swift, not a style declared in a view. See AGENTS.md, Conventions." >&2
    status=1
fi
# The app's primary button is `.primaryButton()` (ButtonStyles.swift): the artboards' inverse pill. A bare `.borderedProminent` is the system accent again, which collides with the five state colours.
hits=$(grep -rnF --include='*.swift' '.borderedProminent' Sources/WorkbenchApp 2>/dev/null \
    | grep -Ev '^[^:]+:[0-9]+:[[:space:]]*//' | grep -v '^Sources/WorkbenchApp/ButtonStyles.swift:' || true)
if [ -n "$hits" ]; then
    echo "$hits"
    echo "error: '.borderedProminent' in Sources/WorkbenchApp/: use .primaryButton() (neutral inverse, not the system accent)." >&2
    status=1
fi
# Every modal is `.modal(...)` (Modal.swift): a card over a veil with a title and Esc and a close button as the way out. The system's
# presentation calls and the pieces of a hand-built overlay are a second look and a second Esc path for the same thing; the Agents card
# had no way to close on Esc for that reason. A new look or behaviour is a new size or prop in Modal.swift; a modal is always centred, so
# there is no placement to pass (docs/DESIGN.md, Modals).
hits=$(grep -rnE --include='*.swift' '\.(sheet|popover|fullScreenCover|alert|confirmationDialog)\(|Color\.black\.opacity\(|\.isModal|\.card\(\.popover' Sources/WorkbenchApp 2>/dev/null \
    | grep -Ev '^[^:]+:[0-9]+:[[:space:]]*//' | grep -Ev '^Sources/WorkbenchApp/(Modal|Card)\.swift:' || true)
if [ -n "$hits" ]; then
    echo "$hits"
    echo "error: a modal built by hand in Sources/WorkbenchApp/: use .modal(\"Title\", isPresented:, size:) (Modal.swift). A new size or" >&2
    echo "       behaviour is a new case or prop there, not a .sheet or an overlay in a view. See AGENTS.md, Conventions." >&2
    status=1
fi
# How a result is told is `Outcome` (Outcome.swift): its symbol, colour and word, so the five state colours each keep one meaning and a symbol
# is never paired with the wrong colour in a view. The symbols that say passed, failed, needs you, unknown and skipped are written in that
# one file; `StatusMark`, `Message` and `FeedLine(.passed, ...)` are how a view uses them. `xmark.circle.fill` is not in this list: it is the
# remove badge, `IconButton.badge`, and is fenced below.
hits=$(grep -rnE --include='*.swift' '"(checkmark\.circle\.fill|exclamationmark\.circle\.fill|exclamationmark\.triangle(\.fill)?|xmark\.octagon\.fill|questionmark\.circle(\.fill)?|minus\.circle(\.fill)?)"' Sources/WorkbenchApp 2>/dev/null \
    | grep -Ev '^[^:]+:[0-9]+:[[:space:]]*//' | grep -v '^Sources/WorkbenchApp/Outcome.swift:' || true)
if [ -n "$hits" ]; then
    echo "$hits"
    echo "error: a result symbol written in a view in Sources/WorkbenchApp/: use an Outcome (StatusMark(.passed), FeedLine(.failed, ...)) or a Message" >&2
    echo "       (Message(.error, text)). A result the cases lack is a new case in Outcome.swift. See AGENTS.md, Conventions." >&2
    status=1
fi
# The spinner, the busy line, the toolbar pill and the icon-only button are components (Busy.swift, Pill.swift, IconButton.swift). `ProgressView()`
# is `Spinner`; `Image(systemName: "xmark")` is `IconButton.close`; `.iconButton(` is `IconButton.raised`, which cannot leave out the name and the
# tooltip an icon alone does not have. A look or size they lack is a new case there, not a copy beside it. A determinate `ProgressView(value:)` stays.
for rule in 'ProgressView\(\)|Spinner (Busy.swift)|Busy.swift' 'systemName: "xmark(\.circle\.fill)?"|IconButton.close or IconButton.badge|IconButton.swift' '\.iconButton\(|IconButton.raised|IconButton.swift|ButtonStyles.swift'; do
    pattern=${rule%%|*}; rest=${rule#*|}; use=${rest%%|*}; files=${rest#*|}
    exempt=$(echo "$files" | sed 's/|/\\|/g')
    hits=$(grep -rnE --include='*.swift' "$pattern" Sources/WorkbenchApp 2>/dev/null | grep -Ev '^[^:]+:[0-9]+:[[:space:]]*//' \
        | grep -Ev "^Sources/WorkbenchApp/($(echo "$files" | sed 's/|/|/g; s/\./\\./g')):" || true)
    if [ -n "$hits" ]; then
        echo "$hits"
        echo "error: '$pattern' written in a view in Sources/WorkbenchApp/: use $use. See AGENTS.md, Conventions." >&2
        status=1
    fi
done
# A single-line text field is `TextInput` (FormControls.swift): the system's bordered, a bare one and the grey well are its looks, and the type
# style, the symbol, the name and the focus are props. A bare `TextField(` or `.textFieldStyle(.roundedBorder)` in a view is a fourth look.
hits=$(grep -rnE --include='*.swift' '(^|[^A-Za-z0-9_])TextField\(|textFieldStyle\(\.roundedBorder\)' Sources/WorkbenchApp 2>/dev/null \
    | grep -Ev '^[^:]+:[0-9]+:[[:space:]]*//' | grep -v '^Sources/WorkbenchApp/FormControls.swift:' || true)
if [ -n "$hits" ]; then
    echo "$hits"
    echo "error: 'TextField(' in Sources/WorkbenchApp/: use TextInput(placeholder, text:, look: .bare/.bordered/.filled) (FormControls.swift). A look it lacks is a new" >&2
    echo "       case there, not a field styled in a view. See AGENTS.md, Conventions." >&2
    status=1
fi
exit $status
