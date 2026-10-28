// Writes the icon macOS shows for a bundle (the Dock's and Finder's) to a PNG, and says whether it is ours: the generated icon has
// amber in it, the generic application icon does not. Usage: swift scripts/app-icon.swift <Workbench.app> <out.png>
import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: swift scripts/app-icon.swift <bundle.app> <out.png>\n".utf8))
    exit(2)
}
let size = 128
let icon = NSWorkspace.shared.icon(forFile: arguments[1])
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
    isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
else { exit(1) }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
icon.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
NSGraphicsContext.restoreGraphicsState()
guard let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: arguments[2]))

// Amber (#F29A1F to #FFC857): a lot of red, some green, little blue.
var amber = 0
for y in 0..<size {
    for x in 0..<size {
        guard let colour = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), colour.alphaComponent > 0.9 else { continue }
        if colour.redComponent > 0.85, colour.greenComponent > 0.55, colour.greenComponent < 0.85, colour.blueComponent < 0.4 {
            amber += 1
        }
    }
}
print("icon \(size)x\(size) amber=\(amber)")
exit(amber > 100 ? 0 : 1)
