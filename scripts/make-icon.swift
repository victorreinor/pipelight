// Draws the app icon into an .iconset folder: swift scripts/make-icon.swift build.noindex/AppIcon.iconset
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func withShadow(_ blur: CGFloat, _ offset: CGFloat, _ alpha: CGFloat, _ draw: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color(0x000000, alpha)
    shadow.shadowBlurRadius = blur
    shadow.shadowOffset = NSSize(width: 0, height: -offset)
    shadow.set()
    draw()
    NSGraphicsContext.restoreGraphicsState()
}

/// Drawn on a 1024-point canvas, y pointing up: a pipeline of three stages on a dark tile,
/// two passed (green, with a check) and the last one running (amber, with the sync arrows).
func drawIcon() {
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
    withShadow(30, 14, 0.3) {
        color(0x1A2333).setFill()
        shape.fill()
    }
    NSGradient(starting: color(0x2B3A55), ending: color(0x121A28))!.draw(in: shape, angle: -90)

    let centers = [262.0, 512.0, 762.0].map { NSPoint(x: $0, y: 512) }
    let radius: CGFloat = 92

    let track = NSBezierPath()
    track.move(to: centers[0])
    track.line(to: centers[2])
    track.lineWidth = 30
    track.lineCapStyle = .round
    color(0x40506E).setStroke()
    track.stroke()
    let done = NSBezierPath()
    done.move(to: centers[0])
    done.line(to: centers[1])
    done.lineWidth = 30
    color(0x34C759).setStroke()
    done.stroke()

    for (index, center) in centers.enumerated() {
        let disc = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        withShadow(24, 8, 0.35) {
            (index < 2 ? color(0x34C759) : color(0xFF9F0A)).setFill()
            disc.fill()
        }
        if index < 2 {
            let tick = NSBezierPath()
            tick.move(to: NSPoint(x: center.x - 40, y: center.y + 2))
            tick.line(to: NSPoint(x: center.x - 12, y: center.y - 28))
            tick.line(to: NSPoint(x: center.x + 42, y: center.y + 32))
            tick.lineWidth = 26
            tick.lineCapStyle = .round
            tick.lineJoinStyle = .round
            NSColor.white.setStroke()
            tick.stroke()
        } else {
            drawSyncArrows(around: center, radius: 44)
        }
    }
}

/// Two arcs chasing each other clockwise, each ending in an arrowhead: the "running" glyph.
func drawSyncArrows(around center: NSPoint, radius: CGFloat) {
    NSColor.white.setStroke()
    NSColor.white.setFill()
    for start in [165.0, -15.0] as [CGFloat] {
        let end = start - 120
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: end + 14, clockwise: true)
        arc.lineWidth = 20
        arc.lineCapStyle = .round
        arc.stroke()

        let angle = end * .pi / 180
        let point = NSPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
        let tangent = NSPoint(x: sin(angle), y: -cos(angle))
        let normal = NSPoint(x: cos(angle), y: sin(angle))
        let head = NSBezierPath()
        head.move(to: NSPoint(x: point.x + tangent.x * 30, y: point.y + tangent.y * 30))
        head.line(to: NSPoint(x: point.x + normal.x * 24 - tangent.x * 8, y: point.y + normal.y * 24 - tangent.y * 8))
        head.line(to: NSPoint(x: point.x - normal.x * 24 - tangent.x * 8, y: point.y - normal.y * 24 - tangent.y * 8))
        head.close()
        head.lineJoinStyle = .round
        head.lineWidth = 6
        head.fill()
        head.stroke()
    }
}

func png(pixels: Int) -> Data {
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current!.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    drawIcon()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

for points in [16, 32, 128, 256, 512] {
    try png(pixels: points).write(to: output.appendingPathComponent("icon_\(points)x\(points).png"))
    try png(pixels: points * 2).write(to: output.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
