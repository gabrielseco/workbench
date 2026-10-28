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
let info = (windows as? [[String: Any]] ?? []).first { window in
    window[kCGWindowOwnerPID as String] as? Int == pid && window[kCGWindowLayer as String] as? Int == 0
}
guard let info, let id = info[kCGWindowNumber as String] as? Int,
    let bounds = info[kCGWindowBounds as String] as? [String: Double]
else { exit(1) }
let rect = ["X", "Y", "Width", "Height"].map { String(Int(bounds[$0] ?? 0)) }
print(([String(id)] + rect).joined(separator: " "))
