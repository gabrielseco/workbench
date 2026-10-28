// Drives one Workbench process's main window through the Accessibility API. The terminal needs Accessibility permission.
// Used by scripts/verify-app.sh, which sets the environment; it never looks for an installed app.
//   WORKBENCH_PID=<pid> swift scripts/ax.swift list             what is on screen: role <tab> label
//   WORKBENCH_PID=<pid> swift scripts/ax.swift tree             the whole hierarchy: indent, role, own text (to find a label)
//   WORKBENCH_PID=<pid> swift scripts/ax.swift press "Doctor"   press the first button whose label is that, else starts with it
//   WORKBENCH_PID=<pid> swift scripts/ax.swift resize 1100 700  set the main window's size in points
//   WORKBENCH_REFUSE=<regex>  a label `press` must not resolve to: checked on the label found, not on the one asked for, because
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
    let parts = [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute].compactMap { attribute(element, $0) as? String }
    return parts.first { !$0.isEmpty } ?? ""
}
/// A button or a combined row is labelled by the text inside it, so it can be found by what it shows.
func text(_ element: AXUIElement, depth: Int = 0) -> String {
    let own = ownText(element)
    guard own.isEmpty, depth < 6 else { return own }
    return children(element).map { text($0, depth: depth + 1) }.filter { !$0.isEmpty }.joined(separator: " ")
}

struct Found {
    let element: AXUIElement
    let role: String
    let label: String
}
let pressable: Set<String> = ["AXButton", "AXMenuButton", "AXPopUpButton", "AXLink", "AXCheckBox"]
/// What a person reads: listed, never pressed. Groups are walked into and never listed: a group carries its children's text.
let readable: Set<String> = ["AXStaticText", "AXTextField", "AXImage"]
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

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

guard let raw = ProcessInfo.processInfo.environment["WORKBENCH_PID"], let pid = Int32(raw), pid > 1,
    let app = NSRunningApplication(processIdentifier: pid)
else { fail("WORKBENCH_PID must be the pid of a running Workbench build") }
guard AXIsProcessTrusted() else { fail("No Accessibility permission for this terminal") }
let windows = attribute(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute) as? [AXUIElement]
guard let window = windows?.first(where: { attribute($0, kAXTitleAttribute) as? String == "Workbench" }) ?? windows?.first
else { fail("No Workbench window") }

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "press":
    guard args.count == 2, !args[1].isEmpty else { fail("usage: press <label>", code: 2) }
    var found: [Found] = []
    walk(window, into: &found)
    let buttons = found.filter { pressable.contains($0.role) }
    guard let hit = buttons.first(where: { $0.label == args[1] }) ?? buttons.first(where: { $0.label.hasPrefix(args[1]) })
    else { fail("Nothing pressable is labelled \"\(args[1])\"") }
    if let refuse = ProcessInfo.processInfo.environment["WORKBENCH_REFUSE"],
        hit.label.range(of: refuse, options: .regularExpression) != nil
    {
        fail("Refused: \"\(args[1])\" is \"\(hit.label)\"")
    }
    let result = AXUIElementPerformAction(hit.element, kAXPressAction as CFString)
    guard result == .success else { fail("failed (\(result.rawValue)) on \(hit.label)") }
    print("pressed \(hit.role) \(hit.label)")
case "resize":
    let sizes = args.dropFirst().compactMap { Int($0) }.filter { $0 > 0 }
    guard args.count == 3, sizes.count == 2 else { fail("resize needs two positive integers: <width> <height>", code: 2) }
    var size = CGSize(width: sizes[0], height: sizes[1])
    guard let value = AXValueCreate(.cgSize, &size) else { exit(1) }
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
    dump(window, depth: 0)
case "list":
    var found: [Found] = []
    walk(window, into: &found)
    for item in found {
        print("\(item.role)\t\(item.label.replacingOccurrences(of: "\n", with: " ").prefix(120))")
    }
default:
    fail("usage: ax.swift list | press <label> | resize <w> <h>", code: 2)
}
