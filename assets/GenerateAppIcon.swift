import AppKit

@main
enum GenerateAppIcon {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let iconset = root.appendingPathComponent(".build/AppIcon.iconset", isDirectory: true)
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let pixels = points * scale
                let suffix = scale == 2 ? "@2x" : ""
                let png = try render(pixels: pixels)
                try png.write(to: iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
                if pixels == 1024 {
                    try png.write(to: root.appendingPathComponent("assets/AppIcon.png"))
                }
            }
        }
    }

    private static func render(pixels: Int) throws -> Data {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels,
            pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: bitmap)
        else { throw CocoaError(.coderInvalidValue) }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        defer { NSGraphicsContext.restoreGraphicsState() }
        context.imageInterpolation = .high
        let transform = NSAffineTransform()
        transform.scale(by: CGFloat(pixels) / 1024)
        transform.concat()

        let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824),
            xRadius: 184, yRadius: 184)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.24)
        shadow.shadowBlurRadius = 24
        shadow.shadowOffset = NSSize(width: 0, height: -14)
        shadow.set()
        NSColor(srgbRed: 0.08, green: 0.09, blue: 0.11, alpha: 1).setFill()
        tile.fill()
        NSGraphicsContext.restoreGraphicsState()

        guard let graphite = NSGradient(starting: NSColor(srgbRed: 0.21, green: 0.23, blue: 0.26, alpha: 1),
            ending: NSColor(srgbRed: 0.075, green: 0.085, blue: 0.105, alpha: 1))
        else { throw CocoaError(.coderInvalidValue) }
        graphite.draw(in: tile, angle: -90)

        NSColor.white.withAlphaComponent(0.12).setStroke()
        let rim = NSBezierPath(roundedRect: NSRect(x: 101, y: 101, width: 822, height: 822),
            xRadius: 183, yRadius: 183)
        rim.lineWidth = 2
        rim.stroke()

        let scale: CGFloat = 37
        let mark = AppMark.image(.halo, .idle, scale: scale)
        mark.isTemplate = false
        let silver = NSImage(size: mark.size, flipped: false) { bounds in
            mark.draw(in: bounds)
            NSColor(srgbRed: 0.945, green: 0.953, blue: 0.969, alpha: 1).setFill()
            bounds.fill(using: .sourceAtop)
            return true
        }
        // Centre the ink bounds, including the halo, rather than the 18 pt canvas.
        let origin = NSPoint(x: 512 - 9.675 * scale, y: 512 - 9.775 * scale)
        silver.draw(in: NSRect(origin: origin, size: mark.size))

        guard let png = bitmap.representation(using: .png, properties: [:])
        else { throw CocoaError(.fileWriteUnknown) }
        return png
    }
}
