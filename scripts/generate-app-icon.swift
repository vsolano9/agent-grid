import AppKit
import Foundation

guard CommandLine.arguments.count == 3 else {
    FileHandle.standardError.write(
        Data("Usage: swift generate-app-icon.swift <master.png> <output-directory>\n".utf8)
    )
    exit(64)
}

let masterURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let fileManager = FileManager.default

guard let source = NSImage(contentsOf: masterURL),
      let sourceRepresentation = source.representations.first,
      sourceRepresentation.pixelsWide == 1024,
      sourceRepresentation.pixelsHigh == 1024
else {
    FileHandle.standardError.write(
        Data("Master icon must be a readable 1024×1024 PNG.\n".utf8)
    )
    exit(65)
}

try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

for size in [16, 32, 64, 128, 256, 512, 1024] {
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
    context.imageInterpolation = NSImageInterpolation.high
    context.shouldAntialias = true

    source.draw(
        in: NSRect(origin: .zero, size: dimensions),
        from: NSRect(origin: .zero, size: source.size),
        operation: .copy,
        fraction: 1,
        respectFlipped: true,
        hints: [.interpolation: NSImageInterpolation.high]
    )

    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    guard let png = representation.representation(
        using: NSBitmapImageRep.FileType.png,
        properties: [:]
    ) else {
        fatalError("Unable to render icon at \(size) px")
    }
    try png.write(to: outputDirectory.appendingPathComponent("icon-\(size).png"))
}
