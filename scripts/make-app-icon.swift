#!/usr/bin/env swift
// Draws Memorri's app icon: the system `brain` symbol in white on a rounded square with one blue gradient, at every size macOS asks for, and
// writes the PNG files and Contents.json into App/Resources/Assets.xcassets/AppIcon.appiconset (spec 010, FR-027, FR-028).
// Run from the repository root: swift scripts/make-app-icon.swift
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "App/Resources/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

/// The macOS icon grid: the artwork is a 824 pt square inside a 1024 pt canvas, with a 185 pt corner radius.
func icon(pixels: Int) -> Data {
    let size = CGFloat(pixels)
    let scale = size / 1024
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    bitmap.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    defer { NSGraphicsContext.restoreGraphicsState() }

    let square = NSRect(x: 100 * scale, y: 100 * scale, width: 824 * scale, height: 824 * scale)
    let shape = NSBezierPath(roundedRect: square, xRadius: 185 * scale, yRadius: 185 * scale)
    NSGradient(starting: NSColor(srgbRed: 0.36, green: 0.66, blue: 1.0, alpha: 1), ending: NSColor(srgbRed: 0.10, green: 0.38, blue: 0.85, alpha: 1))!
        .draw(in: shape, angle: -90)

    // The brain, drawn white and centred, about half the width of the square.
    let configuration = NSImage.SymbolConfiguration(pointSize: 420 * scale, weight: .regular)
    if let symbol = NSImage(systemSymbolName: "brain", accessibilityDescription: nil)?.withSymbolConfiguration(configuration) {
        let fitted = symbol.size
        let target = NSRect(x: square.midX - fitted.width / 2, y: square.midY - fitted.height / 2, width: fitted.width, height: fitted.height)
        let tinted = NSImage(size: fitted)
        tinted.lockFocus()
        symbol.draw(in: NSRect(origin: .zero, size: fitted))
        NSColor.white.set()
        NSRect(origin: .zero, size: fitted).fill(using: .sourceAtop)
        tinted.unlockFocus()
        tinted.draw(in: target)
    } else {
        FileHandle.standardError.write(Data("the brain symbol is not available on this Mac\n".utf8))
        exit(1)
    }
    return bitmap.representation(using: .png, properties: [:])!
}

// (points, scale) as the asset catalog lists them.
let slots: [(Int, Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
var images: [[String: String]] = []
for (points, scale) in slots {
    let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    try icon(pixels: points * scale).write(to: output.appendingPathComponent(name))
    images.append(["filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(points)x\(points)"])
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("Contents.json"))
print("Wrote \(slots.count) icons to \(output.path)")
