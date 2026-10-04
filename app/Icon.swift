import AppKit
import Foundation
let target = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
func drawIcon(size: Int, file: String) throws {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let scale = CGFloat(size) / 1024
    let transform = AffineTransform(scale: scale)
    (transform as NSAffineTransform).concat()
    let outer = NSBezierPath(roundedRect: NSRect(x: 34, y: 34, width: 956, height: 956), xRadius: 220, yRadius: 220)
    let gradient = NSGradient(colors: [NSColor(calibratedRed: 0.06, green: 0.22, blue: 0.78, alpha: 1), NSColor(calibratedRed: 0.13, green: 0.55, blue: 0.97, alpha: 1), NSColor(calibratedRed: 0.32, green: 0.86, blue: 0.98, alpha: 1)])!
    gradient.draw(in: outer, angle: 65)
    NSColor.white.withAlphaComponent(0.18).setFill()
    NSBezierPath(roundedRect: NSRect(x: 125, y: 155, width: 774, height: 714), xRadius: 182, yRadius: 182).fill()
    NSColor.white.withAlphaComponent(0.32).setStroke()
    let border = NSBezierPath(roundedRect: NSRect(x: 125, y: 155, width: 774, height: 714), xRadius: 182, yRadius: 182)
    border.lineWidth = 3; border.stroke()
    if let symbol = NSImage(systemSymbolName: "wifi", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 470, weight: .semibold)) {
        let tinted = NSImage(size: symbol.size)
        tinted.lockFocus(); symbol.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
        NSColor.white.setFill(); NSRect(origin: .zero, size: symbol.size).fill(using: .sourceAtop); tinted.unlockFocus()
        tinted.draw(in: NSRect(x: 246, y: 302, width: 532, height: 410), from: .zero, operation: .sourceOver, fraction: 0.96)
    }
    NSColor.white.withAlphaComponent(0.6).setFill()
    NSBezierPath(roundedRect: NSRect(x: 382, y: 205, width: 260, height: 15), xRadius: 7, yRadius: 7).fill()
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: target.appendingPathComponent(file))
}
for base in [16,32,128,256,512] {
    try drawIcon(size: base, file: "icon_\(base)x\(base).png")
    try drawIcon(size: base*2, file: "icon_\(base)x\(base)@2x.png")
}
