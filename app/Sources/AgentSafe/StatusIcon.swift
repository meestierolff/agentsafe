import AgentSafeCore
import AppKit

/// The menu bar icon: a shield whose outline carries the status, with a small lock inside.
///
/// The outline is green when nothing has leaked, orange when something has, and red when
/// a leaked key is serious. The lock is drawn in the menu bar's own text colour, so it
/// stays readable on light and dark menu bars alike.
enum StatusIcon {
    enum Tone: CaseIterable {
        case clear, leaked, serious

        var colour: NSColor {
            switch self {
            case .clear: return .systemGreen
            case .leaked: return .systemOrange
            case .serious: return .systemRed
            }
        }

        /// The worst open leak decides the colour.
        init(worstLeak: KeySeverity?) {
            switch worstLeak {
            case .none: self = .clear
            case .some(.critical), .some(.high): self = .serious
            case .some(.medium), .some(.low): self = .leaked
            }
        }
    }

    /// Sized to sit level with the other icons in the menu bar.
    static let size = NSSize(width: 21, height: 19)

    static func image(_ tone: Tone) -> NSImage {
        // The drawing block runs each time the icon is drawn, in the menu bar's current
        // appearance, which is what lets `labelColor` come out white or black as needed.
        let image = NSImage(size: size, flipped: false) { rect in
            draw(symbol: "shield", pointSize: 17, weight: .semibold, colour: tone.colour, in: rect, yOffset: 0)
            draw(symbol: "lock.fill", pointSize: 7.5, weight: .bold, colour: .labelColor, in: rect, yOffset: 0.5)
            return true
        }
        image.isTemplate = false  // a template image would be forced to one colour
        return image
    }

    private static func draw(symbol: String, pointSize: CGFloat, weight: NSFont.Weight, colour: NSColor, in rect: NSRect, yOffset: CGFloat) {
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
            .applying(NSImage.SymbolConfiguration(paletteColors: [colour]))
        guard let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else { return }
        let origin = NSPoint(x: rect.midX - glyph.size.width / 2, y: rect.midY - glyph.size.height / 2 + yOffset)
        glyph.draw(in: NSRect(origin: origin, size: glyph.size))
    }
}
