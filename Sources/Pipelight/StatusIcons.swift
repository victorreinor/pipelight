import AppKit
import PipelightCore

/// The colored SF Symbols for the menu bar and the menu rows. Status colors carry the meaning, so these
/// aren't template images; only "no data yet" uses a template that follows the menu bar's color.
enum StatusIcons {
    static let green = NSColor.systemGreen
    static let red = NSColor.systemRed
    static let amber = NSColor.systemOrange
    static let gray = NSColor.systemGray

    /// Frames of the spinning icon shown while something runs.
    static let spinFrames = 12

    static func menuBar(_ overall: Overall, frame: Int = 0) -> NSImage {
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

    /// The icon in front of a branch row. nil state = still loading.
    static func row(_ state: RunState?, error: Bool = false) -> NSImage {
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
    static func symbol(_ name: String, _ color: NSColor, size: CGFloat) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
            .applying(.init(paletteColors: [.white, color]))
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)!
            .withSymbolConfiguration(configuration)!
        image.isTemplate = false
        return image
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
