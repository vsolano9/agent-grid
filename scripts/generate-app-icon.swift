import AppKit
import Foundation

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let fileManager = FileManager.default
try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

let sizes = [16, 32, 64, 128, 256, 512, 1024]
let accents: [NSColor] = [
    NSColor(srgbRed: 0.27, green: 0.84, blue: 0.51, alpha: 1),
    NSColor(srgbRed: 0.33, green: 0.60, blue: 1.00, alpha: 1),
    NSColor(srgbRed: 0.98, green: 0.69, blue: 0.25, alpha: 1),
    NSColor(srgbRed: 0.69, green: 0.44, blue: 0.98, alpha: 1),
]

for size in sizes {
    let dimensions = NSSize(width: size, height: size)
    guard let representation = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: representation) else {
        fatalError("Unable to create pixel buffer at \(size) px")
    }
    representation.size = dimensions
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context

    NSColor(srgbRed: 0.10, green: 0.11, blue: 0.12, alpha: 1).setFill()
    NSBezierPath(rect: NSRect(origin: .zero, size: dimensions)).fill()

    let inset = CGFloat(size) * 0.075
    let terminalRect = NSRect(
        x: inset,
        y: inset,
        width: CGFloat(size) - inset * 2,
        height: CGFloat(size) - inset * 2
    )
    NSColor(srgbRed: 0.018, green: 0.020, blue: 0.022, alpha: 1).setFill()
    NSBezierPath(
        roundedRect: terminalRect,
        xRadius: CGFloat(size) * 0.10,
        yRadius: CGFloat(size) * 0.10
    ).fill()

    NSColor(srgbRed: 0.30, green: 0.32, blue: 0.35, alpha: 1).setStroke()
    let separatorWidth = max(1, CGFloat(size) / 256)
    let vertical = NSBezierPath()
    vertical.lineWidth = separatorWidth
    vertical.move(to: NSPoint(x: terminalRect.midX, y: terminalRect.minY))
    vertical.line(to: NSPoint(x: terminalRect.midX, y: terminalRect.maxY))
    vertical.stroke()
    let horizontal = NSBezierPath()
    horizontal.lineWidth = separatorWidth
    horizontal.move(to: NSPoint(x: terminalRect.minX, y: terminalRect.midY))
    horizontal.line(to: NSPoint(x: terminalRect.maxX, y: terminalRect.midY))
    horizontal.stroke()

    let paneOrigins = [
        NSPoint(x: terminalRect.minX, y: terminalRect.midY),
        NSPoint(x: terminalRect.midX, y: terminalRect.midY),
        NSPoint(x: terminalRect.minX, y: terminalRect.minY),
        NSPoint(x: terminalRect.midX, y: terminalRect.minY),
    ]
    let paneWidth = terminalRect.width / 2
    let paneHeight = terminalRect.height / 2
    let stroke = max(1.2, CGFloat(size) * 0.018)

    for (index, origin) in paneOrigins.enumerated() {
        accents[index].setStroke()
        let chevron = NSBezierPath()
        chevron.lineWidth = stroke
        chevron.lineCapStyle = .round
        let startX = origin.x + paneWidth * 0.23
        let centerY = origin.y + paneHeight * 0.50
        let delta = paneWidth * 0.10
        chevron.move(to: NSPoint(x: startX, y: centerY + delta))
        chevron.line(to: NSPoint(x: startX + delta, y: centerY))
        chevron.line(to: NSPoint(x: startX, y: centerY - delta))
        chevron.stroke()

        let caret = NSBezierPath()
        caret.lineWidth = stroke
        caret.lineCapStyle = .round
        let caretX = origin.x + paneWidth * 0.56
        caret.move(to: NSPoint(x: caretX, y: centerY - delta))
        caret.line(to: NSPoint(x: caretX, y: centerY + delta))
        caret.stroke()
    }

    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    guard let png = representation.representation(using: .png, properties: [:]) else {
        fatalError("Unable to render icon at \(size) px")
    }
    try png.write(to: outputDirectory.appendingPathComponent("icon-\(size).png"))
}
