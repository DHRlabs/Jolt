// Renders the Jolt app icon as 16×16 pixel art at a given output size.
// Usage: swift render-icon.swift <size> <output.png>
import AppKit
import Foundation

let args = CommandLine.arguments
let size = args.count > 1 ? (Int(args[1]) ?? 1024) : 1024
let outPath = args.count > 2 ? args[2] : "icon.png"
let grid = 16
let S = CGFloat(size)
let pixel = S / CGFloat(grid)

let charcoal = NSColor(srgbRed: 5.0 / 255.0, green: 6.0 / 255.0, blue: 8.0 / 255.0, alpha: 1)
let acidGreen = NSColor(srgbRed: 183.0 / 255.0, green: 255.0 / 255.0, blue: 88.0 / 255.0, alpha: 1)
let mint = NSColor(srgbRed: 119.0 / 255.0, green: 215.0 / 255.0, blue: 177.0 / 255.0, alpha: 1)
let offWhite = NSColor(srgbRed: 238.0 / 255.0, green: 242.0 / 255.0, blue: 232.0 / 255.0, alpha: 1)

func inCircle(_ x: Int, _ y: Int, centerX: Int, centerY: Int, radius: Int) -> Bool {
    let dx = x - centerX
    let dy = y - centerY
    return dx * dx + dy * dy <= radius * radius
}

func inEllipse(_ x: Int, _ y: Int, centerX: Int, centerY: Int, radiusX: Int, radiusY: Int) -> Bool {
    let dx = Double(x - centerX) / Double(radiusX)
    let dy = Double(y - centerY) / Double(radiusY)
    return dx * dx + dy * dy <= 1
}

func isInsideIcon(_ x: Int, _ y: Int) -> Bool {
    if y == 0 || y == grid - 1 { return x >= 2 && x <= grid - 3 }
    if y == 1 || y == grid - 2 { return x >= 1 && x <= grid - 2 }
    return true
}

func colorAt(_ x: Int, _ y: Int) -> NSColor {
    guard isInsideIcon(x, y) else { return .clear }

    // A top-down cup: the handle is drawn first so the rim sits cleanly over it.
    var color = charcoal
    if inEllipse(x, y, centerX: 12, centerY: 8, radiusX: 3, radiusY: 4) { color = offWhite }
    if inEllipse(x, y, centerX: 12, centerY: 8, radiusX: 1, radiusY: 2) { color = charcoal }

    let cupCenterX = 7
    let cupCenterY = 8
    if inCircle(x, y, centerX: cupCenterX, centerY: cupCenterY, radius: 6) { color = offWhite }
    if inCircle(x, y, centerX: cupCenterX, centerY: cupCenterY, radius: 4) {
        color = charcoal // espresso surface

        let dx = x - cupCenterX
        let dy = y - cupCenterY
        let distanceSquared = dx * dx + dy * dy
        if (7...11).contains(distanceSquared) {
            color = mint // outer signal ring
        } else if (2...5).contains(distanceSquared) {
            color = acidGreen // inner signal ring
        } else if distanceSquared <= 1 {
            color = mint // signal core
        }
    }
    return color
}

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
    FileHandle.standardError.write("failed to make bitmap\n".data(using: .utf8)!)
    exit(1)
}
rep.size = NSSize(width: S, height: S)

let ctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = ctx
ctx.cgContext.clear(NSRect(x: 0, y: 0, width: S, height: S))
ctx.cgContext.setAllowsAntialiasing(false)
ctx.cgContext.setShouldAntialias(false)
ctx.cgContext.interpolationQuality = .none

for y in 0..<grid {
    for x in 0..<grid {
        colorAt(x, y).setFill()
        NSBezierPath(rect: NSRect(
            x: CGFloat(x) * pixel,
            y: CGFloat(grid - y - 1) * pixel,
            width: pixel,
            height: pixel
        )).fill()
    }
}

NSGraphicsContext.restoreGraphicsState()

guard let data = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("failed to encode png\n".data(using: .utf8)!)
    exit(1)
}
try! data.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath) (\(size)px)")
