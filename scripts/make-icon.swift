// Renders Resources/Artwork/AppIcon.svg into an .icns that follows the macOS icon grid
// (artwork inside the 824 pt squircle area of a 1024 pt canvas, with a soft shadow).
//
//   swift scripts/make-icon.swift <svg> <output.icns>

import AppKit

let args = CommandLine.arguments
guard args.count == 3, let svg = NSImage(contentsOfFile: args[1]) else {
    FileHandle.standardError.write(Data("usage: make-icon <svg> <icns>\n".utf8))
    exit(1)
}
let output = URL(fileURLWithPath: args[2])
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("MouseMaster-\(getpid()).iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    let s = CGFloat(size)
    // The SVG's tile spans 112 of its 128 units; make that the 824/1024 squircle area.
    let k = 0.805 * s / 112
    let drawSize = 128 * k
    let origin = (s - drawSize) / 2
    if size >= 64 {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
        shadow.shadowBlurRadius = s * 0.022
        shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
        shadow.set()
    }
    svg.draw(in: NSRect(x: origin, y: origin - s * 0.004, width: drawSize, height: drawSize))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let entries: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, size) in entries {
    try render(size).write(to: iconset.appendingPathComponent("\(name).png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try p.run()
p.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
exit(p.terminationStatus)
