// Renders the Jolt app icon at a given pixel size.
// Usage: swift render-icon.swift <size> <output.png>
import AppKit
import Foundation

let args = CommandLine.arguments
let size = args.count > 1 ? (Int(args[1]) ?? 1024) : 1024
let outPath = args.count > 2 ? args[2] : "icon.png"
let S = CGFloat(size)

func P(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x * S, y: y * S) }

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
ctx.cgContext.setAllowsAntialiasing(true)
ctx.cgContext.interpolationQuality = .high

// ---- Background squircle with warm coffee gradient ----
let bgRect = NSRect(x: 0, y: 0, width: S, height: S)
let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: S * 0.2237, yRadius: S * 0.2237)
bgPath.addClip()
let amber    = NSColor(srgbRed: 1.00, green: 0.62, blue: 0.11, alpha: 1) // #FF9F1C
let espresso = NSColor(srgbRed: 0.29, green: 0.17, blue: 0.16, alpha: 1) // #4A2C2A
NSGradient(starting: amber, ending: espresso)!.draw(in: bgRect, angle: -90)

// ---- Soft shadow under the mug ----
let shadow = NSBezierPath(ovalIn: NSRect(x: S*0.33, y: S*0.205, width: S*0.34, height: S*0.06))
NSColor(white: 0, alpha: 0.18).setFill()
shadow.fill()

// ---- Lightning bolt (the "jolt"), rising from the cup ----
let bolt = NSBezierPath()
bolt.move(to: P(0.560, 0.855))
bolt.line(to: P(0.410, 0.640))
bolt.line(to: P(0.500, 0.640))
bolt.line(to: P(0.435, 0.500))
bolt.line(to: P(0.600, 0.720))
bolt.line(to: P(0.512, 0.720))
bolt.close()
NSColor(srgbRed: 1.0, green: 0.83, blue: 0.0, alpha: 1).setFill() // #FFD400
bolt.fill()
NSColor(srgbRed: 0.29, green: 0.17, blue: 0.16, alpha: 0.65).setStroke()
bolt.lineWidth = S * 0.010
bolt.lineJoinStyle = .round
bolt.stroke()

// ---- Mug body ----
let body = NSBezierPath(roundedRect: NSRect(x: S*0.35, y: S*0.25, width: S*0.30, height: S*0.25),
                        xRadius: S*0.045, yRadius: S*0.045)
NSColor.white.setFill()
body.fill()

// ---- Mug handle ----
let handle = NSBezierPath()
handle.appendArc(withCenter: P(0.655, 0.375), radius: S*0.075, startAngle: -78, endAngle: 78)
handle.lineWidth = S * 0.032
handle.lineCapStyle = .round
NSColor.white.setStroke()
handle.stroke()

// ---- Coffee line inside the rim ----
let coffee = NSBezierPath(ovalIn: NSRect(x: S*0.375, y: S*0.462, width: S*0.25, height: S*0.028))
NSColor(srgbRed: 0.36, green: 0.20, blue: 0.11, alpha: 1).setFill() // #5C3320
coffee.fill()

NSGraphicsContext.restoreGraphicsState()

guard let data = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("failed to encode png\n".data(using: .utf8)!)
    exit(1)
}
try! data.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath) (\(size)px)")
