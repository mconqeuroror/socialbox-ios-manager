// Original vector artwork for the shared Facebook entry, rendered locally.
import AppKit
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 180, pixelsHigh: 180,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
let bounds = NSRect(x: 0, y: 0, width: 180, height: 180)
NSGradient(starting: NSColor(red: 0.08, green: 0.17, blue: 0.30, alpha: 1),
    ending: NSColor(red: 0.13, green: 0.47, blue: 0.68, alpha: 1))!.draw(in: bounds, angle: 45)
NSColor.white.withAlphaComponent(0.25).setFill()
NSBezierPath(roundedRect: NSRect(x: 36, y: 57, width: 106, height: 82), xRadius: 20, yRadius: 20).fill()
NSColor.white.setFill()
NSBezierPath(roundedRect: NSRect(x: 24, y: 39, width: 106, height: 82), xRadius: 20, yRadius: 20).fill()
let text: NSString = "S"
text.draw(at: NSPoint(x: 60, y: 45), withAttributes: [
    .font: NSFont.systemFont(ofSize: 53, weight: .bold),
    .foregroundColor: NSColor(red: 0.10, green: 0.30, blue: 0.47, alpha: 1)])
NSColor(red: 1, green: 0.77, blue: 0.39, alpha: 1).setFill()
NSBezierPath(ovalIn: NSRect(x: 126, y: 23, width: 26, height: 26)).fill()
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
