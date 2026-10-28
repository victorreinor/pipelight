import AppKit
import PipelightCore

/// The colored SF Symbols for the menu bar and the menu rows. Status colors carry the meaning, so these
/// aren't template images; only "no data yet" uses a template that follows the menu bar's color.
enum StatusIcons {
    static let green = NSColor.systemGreen
    static let red = NSColor.systemRed
    static let amber = NSColor.systemOrange
    static let gray = NSColor.systemGray
    /// "Something new": the dot for a queued PR that finished since the menu was last opened. Blue,
    /// so it never reads as a status color.
    static let badgeColor = NSColor.systemBlue

    /// Frames of the spinning icon shown while something runs.
    static let spinFrames = 12

    static func menuBar(_ overall: Overall, frame: Int = 0, badge: Bool = false) -> NSImage {
        let image = menuBarBase(overall, frame: frame)
        return badge ? badged(image) : image
    }

    private static func menuBarBase(_ overall: Overall, frame: Int) -> NSImage {
        let size: CGFloat = 15
        switch overall {
        case .passed:
            return symbol("checkmark.circle.fill", green, size: size)
        case .failed:
            return symbol("xmark.circle.fill", red, size: size)
        case .running(let failing):
            let image = symbol("arrow.triangle.2.circlepath.circle.fill", failing ? red : amber, size: size)
            return rotated(image, degrees: CGFloat(frame) * 360 / CGFloat(spinFrames))
        case .unknown, .empty:
            let image = NSImage(systemSymbolName: "circle.dashed", accessibilityDescription: "Pipelight")!
                .withSymbolConfiguration(.init(pointSize: size, weight: .regular))!
            image.isTemplate = true
            return image
        }
    }

    /// The icon in front of a branch or PR row. nil state = still loading (or no checks yet).
    static func row(_ state: RunState?, error: Bool = false, badge: Bool = false) -> NSImage {
        let image = rowBase(state, error: error)
        return badge ? badged(image) : image
    }

    private static func rowBase(_ state: RunState?, error: Bool) -> NSImage {
        let size: CGFloat = 14
        if error && state == nil {
            return symbol("exclamationmark.triangle.fill", amber, size: size)
        }
        switch state {
        case .passed: return symbol("checkmark.circle.fill", green, size: size)
        case .failed: return symbol("xmark.circle.fill", red, size: size)
        case .running: return symbol("arrow.triangle.2.circlepath.circle.fill", amber, size: size)
        case .queued: return symbol("clock.fill", amber, size: size)
        case .waiting: return symbol("pause.circle.fill", amber, size: size)
        case .cancelled, .neutral: return symbol("minus.circle.fill", gray, size: size)
        case nil: return symbol("circle.dashed", gray, size: size)
        }
    }

    /// A white glyph on a colored disc, or the whole symbol in `color` when it has a single layer.
    ///
    /// Returned as a plain drawing, not as a symbol image: on the focused screen's menu bar, macOS
    /// redraws symbol images in a status item its own way (the green disc came out as a square there).
    static func symbol(_ name: String, _ color: NSColor, size: CGFloat) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
            .applying(.init(paletteColors: [.white, color]))
        let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)!
            .withSymbolConfiguration(configuration)!
        let image = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            return true
        }
        image.isTemplate = false
        return image
    }

    /// `image` with a small dot on its top-right corner, cut out from the icon by a thin ring so it
    /// stands out on green and red alike.
    static func badged(_ image: NSImage) -> NSImage {
        let diameter = (image.size.height * 0.47).rounded()
        let size = NSSize(width: image.size.width + diameter * 0.3, height: image.size.height + diameter * 0.2)
        let badged = NSImage(size: size, flipped: false) { _ in
            let base = NSRect(origin: .zero, size: image.size)
            if image.isTemplate {
                // Drawn by hand, a template would come out black on a dark menu bar.
                image.draw(in: base)
                NSColor.labelColor.set()
                base.fill(using: .sourceAtop)
            } else {
                image.draw(in: base)
            }
            let dot = NSRect(x: size.width - diameter, y: size.height - diameter, width: diameter, height: diameter)
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            NSBezierPath(ovalIn: dot.insetBy(dx: -1.5, dy: -1.5)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            badgeColor.setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        badged.isTemplate = false
        return badged
    }

    private static func rotated(_ image: NSImage, degrees: CGFloat) -> NSImage {
        let rotated = NSImage(size: image.size, flipped: false) { rect in
            let transform = NSAffineTransform()
            transform.translateX(by: rect.midX, yBy: rect.midY)
            transform.rotate(byDegrees: -degrees)
            transform.translateX(by: -rect.midX, yBy: -rect.midY)
            transform.concat()
            image.draw(in: rect)
            return true
        }
        rotated.isTemplate = false
        return rotated
    }
}
