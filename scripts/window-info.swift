// Prints "<window id> <x> <y> <width> <height>" (global points) for the main window of the process with the pid given as the
// argument, or exits 1 when it has none on screen. CoreGraphics needs no permission to read a window's bounds; only a
// screenshot of it needs Screen Recording. The window is found by pid, never by name, so another running Workbench is never picked.
import CoreGraphics
import Foundation

guard let pid = CommandLine.arguments.dropFirst().first.flatMap({ Int($0) }) else {
    FileHandle.standardError.write(Data("usage: swift scripts/window-info.swift <pid>\n".utf8))
    exit(2)
}
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
// `popover` as the second argument picks the status item's popover instead: this pid's largest window above the normal layer
// (the status item itself is a sliver of the menu bar).
let wantsPopover = CommandLine.arguments.dropFirst(2).first == "popover"
let ours = (windows as? [[String: Any]] ?? []).filter { $0[kCGWindowOwnerPID as String] as? Int == pid }
func area(_ window: [String: Any]) -> Double {
    let b = window[kCGWindowBounds as String] as? [String: Double] ?? [:]
    return (b["Width"] ?? 0) * (b["Height"] ?? 0)
}
let info =
    wantsPopover
    ? ours.filter { ($0[kCGWindowLayer as String] as? Int ?? 0) > 0 && area($0) > 5000 }.max { area($0) < area($1) }
    : ours.first { $0[kCGWindowLayer as String] as? Int == 0 }
guard let info, let id = info[kCGWindowNumber as String] as? Int,
    let bounds = info[kCGWindowBounds as String] as? [String: Double]
else { exit(1) }
let rect = ["X", "Y", "Width", "Height"].map { String(Int(bounds[$0] ?? 0)) }
print(([String(id)] + rect).joined(separator: " "))
