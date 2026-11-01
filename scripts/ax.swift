// Drives one Workbench process's main window through the Accessibility API. The terminal needs Accessibility permission.
// Used by scripts/verify-app.sh, which sets the environment; it never looks for an installed app.
//   WORKBENCH_PID=<pid> swift scripts/ax.swift list             what is on screen: role <tab> label
//   WORKBENCH_PID=<pid> swift scripts/ax.swift tree             the whole hierarchy: indent, role, own text (to find a label)
//   WORKBENCH_PID=<pid> swift scripts/ax.swift press "Doctor"   press the first button whose label is that, else starts with it
//   WORKBENCH_PID=<pid> swift scripts/ax.swift type "text"     set the text of the window's focused text field, else its only one
//   WORKBENCH_PID=<pid> swift scripts/ax.swift focus "What must hold"  focus the text field or area with that text or placeholder
//   WORKBENCH_PID=<pid> swift scripts/ax.swift click "Judge"    a real left click in the middle of what is labelled that, only when this
//                             pid's window is the topmost there (the cursor is put back after)
//   WORKBENCH_PID=<pid> swift scripts/ax.swift hover "It works 1."  move the pointer there (a hover state shows); same rule, cursor put back
//   WORKBENCH_PID=<pid> swift scripts/ax.swift key tab          one key (return, tab, escape, up, down) sent to that pid only
//   WORKBENCH_PID=<pid> swift scripts/ax.swift typekeys "text"  press the keys of that text (at most 200 printable characters), sent to that
//                             pid only, into the focused field; `focus` selects what the field holds, so the text replaces it and the
//                             app sees real edits (`type` sets the value without them, which an app that waits for edits does not see)
//   WORKBENCH_PID=<pid> swift scripts/ax.swift scroll 5         scroll the window's content down by that many steps (-30 to 30, up is negative)
//   WORKBENCH_PID=<pid> swift scripts/ax.swift resize 1100 700  set the main window's size in points
//   WORKBENCH_AX_FIXTURE=<file>  a stand-in for the live tree, for scripts/test-verify-app-ax.sh: one `role<TAB>label` per line. `list`,
//                             `press` and `type` work on it, they only name what they would press or fill, and no process or permission is needed.
//   WORKBENCH_REFUSE=<regex>  a label `press`, `click` and `hover` must not resolve to: checked on the label found, not on the one asked for, because
//                             the match is by prefix ("Eve" resolves to "Event log 5")
import AppKit
import ApplicationServices

func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}
func children(_ element: AXUIElement) -> [AXUIElement] {
    attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
}
func ownText(_ element: AXUIElement) -> String {
    // An empty text field is found by its placeholder.
    let parts = [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXPlaceholderValueAttribute]
        .compactMap { attribute(element, $0) as? String }
    return parts.first { !$0.isEmpty } ?? ""
}
/// A button or a combined row is labelled by the text inside it, so it can be found by what it shows.
func text(_ element: AXUIElement, depth: Int = 0) -> String {
    let own = ownText(element)
    guard own.isEmpty, depth < 6 else { return own }
    return children(element).map { text($0, depth: depth + 1) }.filter { !$0.isEmpty }.joined(separator: " ")
}

struct Found {
    let element: AXUIElement?  // nil for a line of a fixture file
    let role: String
    let label: String
}
let pressable: Set<String> = ["AXButton", "AXMenuButton", "AXPopUpButton", "AXLink", "AXCheckBox", "AXRadioButton"]
/// What a person reads: listed, never pressed. Groups are walked into and never listed: a group carries its children's text.
let readable: Set<String> = ["AXStaticText", "AXTextField", "AXTextArea", "AXImage"]
func walk(_ element: AXUIElement, into found: inout [Found]) {
    for child in children(element) {
        let role = attribute(child, kAXRoleAttribute) as? String ?? ""
        let label = text(child)
        // A button with no label (the window's close, minimise and zoom) cannot be named, so it is neither listed nor pressed.
        if !label.isEmpty, pressable.contains(role) || readable.contains(role) {
            found.append(Found(element: child, role: role, label: label))
            if pressable.contains(role) { continue }
        }
        walk(child, into: &found)
    }
}

/// The text fields and text areas of the window, labelled or not: an empty one has no text to find it by.
let editableRoles: Set<String> = ["AXTextField", "AXTextArea"]
func editables(_ element: AXUIElement, depth: Int = 0) -> [AXUIElement] {
    guard depth < 14 else { return [] }
    return children(element).flatMap { child -> [AXUIElement] in
        let role = attribute(child, kAXRoleAttribute) as? String ?? ""
        return (editableRoles.contains(role) ? [child] : []) + editables(child, depth: depth + 1)
    }
}
/// What `type` accepts: printable text and newlines, bounded, so a script cannot paste a payload.
let typeLimit = 2000

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

let args = Array(CommandLine.arguments.dropFirst())
var found: [Found] = []
var window: AXUIElement?
if let path = ProcessInfo.processInfo.environment["WORKBENCH_AX_FIXTURE"] {
    let supported = ["list", "press", "type", "typekeys", "focus", "click", "hover", "key"]
    guard supported.contains(args.first ?? ""), let text = try? String(contentsOfFile: path, encoding: .utf8)
    else { fail("a fixture supports list and press, and must be a readable file", code: 2) }
    for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
        let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        if parts.count == 2, !parts[1].isEmpty { found.append(Found(element: nil, role: parts[0], label: parts[1])) }
    }
} else {
    guard let raw = ProcessInfo.processInfo.environment["WORKBENCH_PID"], let pid = Int32(raw), pid > 1,
        let app = NSRunningApplication(processIdentifier: pid)
    else { fail("WORKBENCH_PID must be the pid of a running Workbench build") }
    guard AXIsProcessTrusted() else { fail("No Accessibility permission for this terminal") }
    let windows = attribute(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute) as? [AXUIElement]
    guard let main = windows?.first(where: { attribute($0, kAXTitleAttribute) as? String == "Workbench" }) ?? windows?.first
    else { fail("No Workbench window") }
    window = main
    walk(main, into: &found)
}

var targetPID: pid_t = 0
if window != nil, let raw = ProcessInfo.processInfo.environment["WORKBENCH_PID"], let pid = Int32(raw) { targetPID = pid }

/// What `press`, `click` and `hover` name: an exact label before a prefix, and never one the refusal list covers (checked on the label
/// found, because "Eve" resolves to "Event log 5").
func resolved(_ label: String, roles: Set<String>? = nil) -> Found {
    let pool = roles.map { allowed in found.filter { allowed.contains($0.role) } } ?? found
    guard let hit = pool.first(where: { $0.label == label }) ?? pool.first(where: { $0.label.hasPrefix(label) })
    else { fail("Nothing is labelled \"\(label)\"") }
    let refuse = ProcessInfo.processInfo.environment["WORKBENCH_REFUSE"]
    if let refuse, hit.label.range(of: refuse, options: .regularExpression) != nil {
        fail("Refused: \"\(label)\" is \"\(hit.label)\"")
    }
    return hit
}

func frame(of element: AXUIElement) -> CGRect? {
    guard let position = attribute(element, kAXPositionAttribute), let size = attribute(element, kAXSizeAttribute) else {
        return nil
    }
    var origin = CGPoint.zero
    var extent = CGSize.zero
    // swiftlint:disable force_cast
    guard AXValueGetValue(position as! AXValue, .cgPoint, &origin), AXValueGetValue(size as! AXValue, .cgSize, &extent) else {
        return nil
    }
    // swiftlint:enable force_cast
    return CGRect(origin: origin, size: extent)
}

/// The middle of an element, which must be inside the window: a row scrolled out of view cannot be clicked, and a click is never sent
/// to a point outside this pid's window.
func middle(of element: AXUIElement) -> CGPoint {
    guard let window, let box = frame(of: element), let bounds = frame(of: window) else { fail("That has no position on screen") }
    let point = CGPoint(x: box.midX, y: box.midY)
    guard bounds.contains(point) else { fail("That is outside the window (scroll to it first)") }
    return point
}

let events = CGEventSource(stateID: .combinedSessionState)

/// Whether the topmost window at `point` is this pid's: a click or a move is a real pointer event (events posted straight to a process
/// are dropped by AppKit, which cannot tell which window they are for), so it must never be sent where another app's window is on top.
func ownsTopWindow(at point: CGPoint) -> Bool {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    for entry in list {
        guard let bounds = entry[kCGWindowBounds as String] as? [String: CGFloat], (entry[kCGWindowLayer as String] as? Int) == 0,
            let x = bounds["X"], let y = bounds["Y"], let width = bounds["Width"], let height = bounds["Height"]
        else { continue }
        if CGRect(x: x, y: y, width: width, height: height).contains(point) {
            return (entry[kCGWindowOwnerPID as String] as? Int32) == targetPID
        }
    }
    return false
}

/// Whether what Accessibility finds at `point` is `target` or something inside it (a button's own label). An element scrolled out of view
/// still has a position, which can be over another control (the footer's `Event log`) or over its scroll area; both are refused.
func isTheTarget(at point: CGPoint, _ target: AXUIElement) -> Bool {
    var hit: AXUIElement?
    let app = AXUIElementCreateApplication(targetPID)
    guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit) == .success, let hit else { return false }
    func chain(_ start: AXUIElement) -> [AXUIElement] {
        var out = [start]
        var current = start
        while out.count < 12, let parent = attribute(current, kAXParentAttribute) {
            // swiftlint:disable:next force_cast
            current = parent as! AXUIElement
            out.append(current)
        }
        return out
    }
    return chain(hit).contains { CFEqual($0, target) }
}

/// Puts this pid's window in front: `activate()` alone is not honoured when another app (the terminal) holds the focus.
func bringToFront() {
    let app = AXUIElementCreateApplication(targetPID)
    _ = AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    if let window { _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString) }
    NSRunningApplication(processIdentifier: targetPID)?.activate()
}

func mouse(_ type: CGEventType, at point: CGPoint) {
    let event = CGEvent(mouseEventSource: events, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
    event?.setIntegerValueField(.mouseEventClickState, value: 1)
    event?.post(tap: .cghidEventTap)
}

switch args.first {
case "focus":
    guard args.count == 2, !args[1].isEmpty else { fail("usage: focus <text or placeholder>", code: 2) }
    let hit = resolved(args[1], roles: editableRoles)
    guard let element = hit.element else {
        print("focused (fixture) \(hit.role) \(hit.label)")
        exit(0)
    }
    let result = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    guard result == .success else { fail("focus failed (\(result.rawValue)) on \(hit.label)") }
    // What the field holds is selected, so the keys typed next replace it.
    var everything = CFRange(location: 0, length: (attribute(element, kAXValueAttribute) as? String)?.utf16.count ?? 0)
    if let range = AXValueCreate(.cfRange, &everything) {
        _ = AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, range)
    }
    print("focused \(hit.role) \(hit.label)")
case "click", "hover":
    guard args.count == 2, !args[1].isEmpty else { fail("usage: \(args[0]) <label>", code: 2) }
    let hit = resolved(args[1])
    guard let element = hit.element else {
        print("\(args[0])ed (fixture) \(hit.role) \(hit.label)")
        exit(0)
    }
    let point = middle(of: element)
    bringToFront()
    usleep(300_000)
    guard ownsTopWindow(at: point) else { fail("Another window is on top there: nothing was sent") }
    guard isTheTarget(at: point, element) else {
        fail("\(hit.label) is not what is at that point (scrolled out of view, or covered): nothing was sent")
    }
    let before = CGEvent(source: nil)?.location ?? point
    defer { CGWarpMouseCursorPosition(before) }
    mouse(.mouseMoved, at: point)
    usleep(150_000)
    if args[0] == "click" {
        mouse(.leftMouseDown, at: point)
        usleep(60_000)
        mouse(.leftMouseUp, at: point)
    }
    print("\(args[0])ed \(hit.role) \(hit.label)")
case "key":
    // Only keys that move or end a field's edit: no letters, no modifiers, so no shortcut (⌘Q, ⌘W) can be sent.
    let codes: [String: CGKeyCode] = ["return": 36, "tab": 48, "escape": 53, "down": 125, "up": 126]
    guard args.count == 2, let code = codes[args[1]] else { fail("usage: key return|tab|escape|up|down", code: 2) }
    guard window != nil else {
        print("key (fixture) \(args[1])")
        exit(0)
    }
    bringToFront()
    usleep(200_000)
    for down in [true, false] {
        let event = CGEvent(keyboardEventSource: events, virtualKey: code, keyDown: down)
        event?.postToPid(targetPID)
        usleep(50_000)
    }
    print("key \(args[1])")
case "typekeys":
    guard args.count == 2, !args[1].isEmpty else { fail("usage: typekeys <text>", code: 2) }
    guard args[1].count <= 200, !args[1].unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f })
    else { fail("typekeys takes at most 200 printable characters (no newline, tab or control character: use `key`)", code: 2) }
    guard window != nil else {
        print("typekeys (fixture) \(args[1].count) characters")
        exit(0)
    }
    bringToFront()
    usleep(200_000)
    for character in args[1] {
        let units = Array(String(character).utf16)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: events, virtualKey: 0, keyDown: down)
            event?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            event?.postToPid(targetPID)
            usleep(8_000)
        }
    }
    print("typekeys \(args[1].count) characters")
case "scroll":
    guard args.count == 2, let steps = Int32(args[1]), (-30...30).contains(steps), steps != 0 else {
        fail("usage: scroll <steps from -30 to 30, not 0; positive scrolls down>", code: 2)
    }
    guard let window, let bounds = frame(of: window) else { fail("No Workbench window") }
    let point = CGPoint(x: bounds.midX, y: bounds.midY)
    bringToFront()
    usleep(200_000)
    mouse(.mouseMoved, at: point)
    // A step is 40 points; the wheel's sign is the other way round (positive moves the content down), so it is flipped here.
    CGEvent(scrollWheelEvent2Source: events, units: .pixel, wheelCount: 1, wheel1: -steps * 40, wheel2: 0, wheel3: 0)?
        .postToPid(targetPID)
    print("scrolled \(steps) steps")
case "press":
    guard args.count == 2, !args[1].isEmpty else { fail("usage: press <label>", code: 2) }
    let buttons = found.filter { pressable.contains($0.role) }
    guard let hit = buttons.first(where: { $0.label == args[1] }) ?? buttons.first(where: { $0.label.hasPrefix(args[1]) })
    else { fail("Nothing pressable is labelled \"\(args[1])\"") }
    let refuse = ProcessInfo.processInfo.environment["WORKBENCH_REFUSE"]
    if let refuse, hit.label.range(of: refuse, options: .regularExpression) != nil {
        fail("Refused: \"\(args[1])\" is \"\(hit.label)\"")
    }
    guard let element = hit.element else {
        print("pressed (fixture) \(hit.role) \(hit.label)")
        exit(0)
    }
    let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
    guard result == .success else { fail("failed (\(result.rawValue)) on \(hit.label)") }
    print("pressed \(hit.role) \(hit.label)")
case "type":
    guard args.count == 2, !args[1].isEmpty else { fail("usage: type <text>", code: 2) }
    guard args[1].count <= typeLimit, !args[1].unicodeScalars.contains(where: { $0.value < 0x20 && $0 != "\n" && $0 != "\t" })
    else { fail("type takes at most \(typeLimit) characters, with no control characters but newline and tab", code: 2) }
    guard let window else {
        // A fixture names the field it would fill: its first `AXTextArea` or `AXTextField` line.
        guard let field = found.first(where: { editableRoles.contains($0.role) }) else { fail("No text field to type into") }
        print("typed (fixture) \(field.role) \(field.label)")
        exit(0)
    }
    let fields = editables(window)
    let focused = fields.first { (attribute($0, kAXFocusedAttribute) as? Bool) == true }
    guard let field = focused ?? (fields.count == 1 ? fields.first : nil) else {
        fail(fields.isEmpty ? "No text field to type into" : "\(fields.count) text fields and none is focused: nothing was typed")
    }
    let result = AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, args[1] as CFString)
    guard result == .success else { fail("typing failed (\(result.rawValue))") }
    print("typed \(args[1].count) characters into \(attribute(field, kAXRoleAttribute) as? String ?? "a text field")")
case "resize":
    let sizes = args.dropFirst().compactMap { Int($0) }.filter { $0 > 0 }
    guard args.count == 3, sizes.count == 2 else { fail("resize needs two positive integers: <width> <height>", code: 2) }
    var size = CGSize(width: sizes[0], height: sizes[1])
    guard let window, let value = AXValueCreate(.cgSize, &size) else { exit(1) }
    let result = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
    guard result == .success else { fail("resize failed (\(result.rawValue))") }
    print("resized to \(sizes[0])x\(sizes[1])")
case "tree":
    func dump(_ element: AXUIElement, depth: Int) {
        guard depth < 12 else { return }
        let role = attribute(element, kAXRoleAttribute) as? String ?? "?"
        let own = ownText(element).replacingOccurrences(of: "\n", with: " ").prefix(80)
        print(String(repeating: "  ", count: depth) + role + (own.isEmpty ? "" : "\t" + own))
        for child in children(element) { dump(child, depth: depth + 1) }
    }
    if let window { dump(window, depth: 0) }
case "list":
    for item in found {
        print("\(item.role)\t\(item.label.replacingOccurrences(of: "\n", with: " ").prefix(120))")
    }
case "status":
    // The app's own status item (the menu bar's extras menu of this pid only): a press opens or closes its popover.
    guard window != nil else {
        print("status (fixture)")
        exit(0)
    }
    let app = AXUIElementCreateApplication(targetPID)
    guard let bar = attribute(app, "AXExtrasMenuBar"), let item = children(bar as! AXUIElement).first
    else { fail("This app has no status item") }
    guard AXUIElementPerformAction(item, kAXPressAction as CFString) == .success else { fail("pressing the status item failed") }
    print("pressed status item: \(text(item))")
case "popover", "popover-press":
    // What the status item's popover shows: every window of this pid that is not the main one.
    guard window != nil else { fail("a fixture has no popover") }
    let app = AXUIElementCreateApplication(targetPID)
    let others = (attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []).filter {
        attribute($0, kAXTitleAttribute) as? String != "Workbench"
    }
    var popover: [Found] = []
    for other in others { walk(other, into: &popover) }
    if args[0] == "popover" {
        guard !others.isEmpty else { fail("The popover is not open: press the status item first") }
        for item in popover { print("\(item.role)\t\(item.label.replacingOccurrences(of: "\n", with: " ").prefix(120))") }
        exit(0)
    }
    guard args.count == 2, !args[1].isEmpty else { fail("usage: popover-press <label>", code: 2) }
    let buttons = popover.filter { pressable.contains($0.role) }
    guard let hit = buttons.first(where: { $0.label == args[1] }) ?? buttons.first(where: { $0.label.hasPrefix(args[1]) })
    else { fail("Nothing pressable in the popover is labelled \"\(args[1])\"") }
    if let refuse = ProcessInfo.processInfo.environment["WORKBENCH_REFUSE"], hit.label.range(of: refuse, options: .regularExpression) != nil {
        fail("Refused: \"\(args[1])\" is \"\(hit.label)\"")
    }
    guard let element = hit.element, AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    else { fail("failed on \(hit.label)") }
    print("pressed \(hit.role) \(hit.label)")
default:
    fail(
        "usage: ax.swift list | press <label> | type <text> | focus <field> | click <label> | hover <label> | typekeys <text>"
            + " | key <key> | scroll <n> | resize <w> <h>",
        code: 2)
}
