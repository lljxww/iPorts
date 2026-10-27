import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fatalError("Usage: swift create-icon.swift <output.iconset>")
}
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        guard
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ), let context = NSGraphicsContext(bitmapImageRep: bitmap)
        else {
            throw CocoaError(.fileWriteUnknown)
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        NSColor(calibratedRed: 0.065, green: 0.09, blue: 0.11, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 60, y: 60, width: 904, height: 904), xRadius: 205, yRadius: 205)
            .fill()
        let mint = NSColor(calibratedRed: 0.39, green: 0.89, blue: 0.75, alpha: 1)
        mint.setStroke()
        let cable = NSBezierPath()
        cable.lineWidth = 38
        cable.lineCapStyle = .round
        cable.move(to: NSPoint(x: 512, y: 273))
        cable.line(to: NSPoint(x: 512, y: 373))
        cable.stroke()
        let port = NSBezierPath(
            roundedRect: NSRect(x: 263, y: 373, width: 498, height: 280), xRadius: 140, yRadius: 140)
        port.lineWidth = 42
        port.stroke()
        mint.withAlphaComponent(0.16).setFill()
        port.fill()
        mint.setFill()
        NSBezierPath(roundedRect: NSRect(x: 351, y: 483, width: 322, height: 60), xRadius: 30, yRadius: 30)
            .fill()
        for x in [430, 512, 594] {
            NSBezierPath(ovalIn: NSRect(x: x - 12, y: 730, width: 24, height: 24)).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let suffix = scale == 2 ? "@2x" : ""
        try png.write(to: directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
