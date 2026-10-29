// Pastes a picture into one Workbench process: puts it on the clipboard, sends ⌘V to that process only, puts the old clipboard back.
// Used by scripts/verify-app.sh, which has already checked the pid. The keystroke goes to the process, not to whatever is in front,
// so no other app can receive it. The terminal needs Accessibility permission.
//   WORKBENCH_PID=<pid> swift scripts/paste.swift [image-file]   a generated picture when no file is given
import AppKit
import ApplicationServices

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

guard let raw = ProcessInfo.processInfo.environment["WORKBENCH_PID"], let pid = Int32(raw), pid > 1,
    NSRunningApplication(processIdentifier: pid) != nil
else { fail("WORKBENCH_PID must be the pid of a running Workbench build") }
guard AXIsProcessTrusted() else { fail("No Accessibility permission for this terminal") }

let args = Array(CommandLine.arguments.dropFirst())
guard args.count <= 1 else { fail("usage: paste [image-file]", code: 2) }
let image: NSImage
if let path = args.first {
    let url = URL(fileURLWithPath: path)
    let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values?.isRegularFile == true, (values?.fileSize ?? .max) <= 5 << 20, let loaded = NSImage(contentsOf: url) else {
        fail("\(path) is not an image file of at most 5 MiB", code: 2)
    }
    image = loaded
} else {
    image = NSImage(size: NSSize(width: 160, height: 100), flipped: false) { rect in
        NSColor.systemOrange.setFill()
        rect.fill()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: rect.insetBy(dx: 40, dy: 25)).fill()
        return true
    }
}
guard let tiff = image.tiffRepresentation else { fail("the picture could not be read") }

let board = NSPasteboard.general
let saved: [[(NSPasteboard.PasteboardType, Data)]] = (board.pasteboardItems ?? []).map { item in
    item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
}
board.clearContents()
board.setData(tiff, forType: .tiff)

let source = CGEventSource(stateID: .combinedSessionState)
for down in [true, false] {
    let event = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: down)  // V
    event?.flags = .maskCommand
    event?.postToPid(pid)
}
// The app reads the clipboard when it handles the key; give it time before the old contents come back.
usleep(600_000)
board.clearContents()
for item in saved {
    let restored = NSPasteboardItem()
    for (type, data) in item { restored.setData(data, forType: type) }
    board.writeObjects([restored])
}
print("pasted a \(Int(image.size.width))x\(Int(image.size.height)) picture into \(pid)")
