// Generates the app icon (Resources/AppIcon.png + Resources/AppIcon.icns).
// Run from the repository root: `make icon` or `swift scripts/generate-appicon.swift`.
//
// Design: a dark rounded square with a single hourglass. Green sand sits in the
// lower bulb - time until the 5-hour limit resets. No rings, no blue, no text.
// The live menu-bar icon is drawn separately in TrayIcon.swift.

import AppKit
import Foundation

let size: CGFloat = 1024
let cx: CGFloat = 512
let fileManager = FileManager.default

try? fileManager.createDirectory(atPath: "Resources", withIntermediateDirectories: true)

// MARK: - Draw the 1024x1024 master image

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(size),
    pixelsHigh: Int(size),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
), let context = NSGraphicsContext(bitmapImageRep: rep) else {
    fatalError("Cannot create bitmap context")
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context

NSColor.clear.setFill()
NSRect(x: 0, y: 0, width: size, height: size).fill()

// Rounded-square background with a subtle vertical gradient and a rim light.
let square = NSRect(x: 0, y: 0, width: size, height: size)
NSGraphicsContext.saveGraphicsState()
NSBezierPath(roundedRect: square, xRadius: 230, yRadius: 230).addClip()
NSGradient(
    starting: NSColor(calibratedRed: 0.17, green: 0.19, blue: 0.24, alpha: 1),
    ending: NSColor(calibratedRed: 0.06, green: 0.07, blue: 0.10, alpha: 1)
)?.draw(in: square, angle: -90)
NSColor.white.withAlphaComponent(0.10).setStroke()
let rim = NSBezierPath(
    roundedRect: square.insetBy(dx: 7, dy: 7),
    xRadius: 224,
    yRadius: 224
)
rim.lineWidth = 4
rim.stroke()
NSGraphicsContext.restoreGraphicsState()

// Geometry of the hourglass.
let halfWidth: CGFloat = 250
let capTop: CGFloat = 762
let capBottom: CGFloat = 262
let neckUpper: CGFloat = 530
let neckLower: CGFloat = 494
let neckHalf: CGFloat = 28

// Green sand in the lower bulb (drawn first, under the glass outline).
let sand = NSBezierPath()
sand.move(to: NSPoint(x: cx - 172, y: capBottom + 26))
sand.line(to: NSPoint(x: cx + 172, y: capBottom + 26))
sand.line(to: NSPoint(x: cx + neckHalf, y: neckLower))
sand.line(to: NSPoint(x: cx - neckHalf, y: neckLower))
sand.close()
NSGradient(
    starting: NSColor(calibratedRed: 0.24, green: 0.86, blue: 0.42, alpha: 1),
    ending: NSColor(calibratedRed: 0.14, green: 0.68, blue: 0.33, alpha: 1)
)?.draw(in: sand, angle: -90)

// Glass outline: two trapezoids joined by a narrow neck.
let upper = NSBezierPath()
upper.move(to: NSPoint(x: cx - halfWidth, y: capTop))
upper.line(to: NSPoint(x: cx + halfWidth, y: capTop))
upper.line(to: NSPoint(x: cx + neckHalf, y: neckUpper))
upper.line(to: NSPoint(x: cx - neckHalf, y: neckUpper))
upper.close()

let lower = NSBezierPath()
lower.move(to: NSPoint(x: cx - neckHalf, y: neckLower))
lower.line(to: NSPoint(x: cx + neckHalf, y: neckLower))
lower.line(to: NSPoint(x: cx + halfWidth, y: capBottom))
lower.line(to: NSPoint(x: cx - halfWidth, y: capBottom))
lower.close()

let glassColor = NSColor.white.withAlphaComponent(0.94)
for path in [upper, lower] {
    path.lineWidth = 24
    path.lineJoinStyle = .round
    glassColor.setStroke()
    path.stroke()
}

// Caps.
glassColor.setFill()
NSRect(x: cx - halfWidth - 22, y: capTop - 6, width: (halfWidth + 22) * 2, height: 26).fill()
NSRect(x: cx - halfWidth - 22, y: capBottom - 20, width: (halfWidth + 22) * 2, height: 26).fill()

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("Cannot encode PNG")
}
let pngURL = URL(fileURLWithPath: "Resources/AppIcon.png")
try png.write(to: pngURL)
print("wrote \(pngURL.path) (\(png.count) bytes)")

// MARK: - Build the .iconset and convert to .icns

func run(_ tool: String, _ arguments: [String]) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    do {
        try process.run()
    } catch {
        fatalError("Cannot run \(tool): \(error)")
    }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        fatalError("\(tool) failed with status \(process.terminationStatus)")
    }
}

let iconset = fileManager.temporaryDirectory
    .appendingPathComponent("OpenCodeLimits-AppIcon.iconset")
try? fileManager.removeItem(at: iconset)
try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)

let variants: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

for (name, pixels) in variants {
    run("/usr/bin/sips", [
        "-z", String(pixels), String(pixels),
        pngURL.path,
        "--out", iconset.appendingPathComponent(name).path,
    ])
}

let icnsURL = URL(fileURLWithPath: "Resources/AppIcon.icns")
run("/usr/bin/iconutil", [
    "-c", "icns", iconset.path, "-o", icnsURL.path,
])
try? fileManager.removeItem(at: iconset)

print("wrote \(icnsURL.path)")
