import SwiftUI

/// The look: early-2000s Mac OS X. Pinstripes, gel buttons, brushed metal, and one
/// hi-fi style LCD readout. Everything here is drawn in code; no Apple artwork is reused.
enum Aqua {
    // Palette
    static let blue = Color(red: 0.18, green: 0.50, blue: 0.91)
    static let blueLight = Color(red: 0.55, green: 0.77, blue: 1.0)
    static let blueDeep = Color(red: 0.04, green: 0.31, blue: 0.70)
    static let ink = Color(red: 0.12, green: 0.17, blue: 0.23)
    static let inkSoft = Color(red: 0.33, green: 0.38, blue: 0.45)
    static let paper = Color(red: 0.945, green: 0.953, blue: 0.965)
    static let stripe = Color(red: 0.895, green: 0.910, blue: 0.933)
    static let metalLight = Color(red: 0.86, green: 0.87, blue: 0.89)
    static let metalDark = Color(red: 0.66, green: 0.68, blue: 0.71)
    static let rowTint = Color(red: 0.93, green: 0.95, blue: 0.99)

    static let lcdBackground = Color(red: 0.05, green: 0.11, blue: 0.09)
    static let lcdGreen = Color(red: 0.49, green: 1.0, blue: 0.70)
    static let lcdAmber = Color(red: 1.0, green: 0.71, blue: 0.21)
    static let lcdRed = Color(red: 1.0, green: 0.33, blue: 0.27)

    static let ok = Color(red: 0.18, green: 0.66, blue: 0.31)
    static let warn = Color(red: 0.93, green: 0.60, blue: 0.07)
    static let danger = Color(red: 0.85, green: 0.19, blue: 0.15)

    /// Lucida Grande was the Mac's system font for the whole Aqua era and still ships with macOS.
    static func font(_ size: CGFloat, bold: Bool = false) -> Font {
        .custom(bold ? "LucidaGrande-Bold" : "LucidaGrande", size: size)
    }

    static func mono(_ size: CGFloat, bold: Bool = false) -> Font {
        .system(size: size, weight: bold ? .bold : .medium, design: .monospaced)
    }
}

/// Thin horizontal pinstripes, the signature Aqua window background.
struct Pinstripes: View {
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Aqua.paper))
            var y: CGFloat = 0
            while y < size.height {
                context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(Aqua.stripe))
                y += 4
            }
        }
    }
}

/// Brushed metal: a vertical gradient with fine horizontal grain.
struct BrushedMetal: View {
    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            context.fill(Path(rect), with: .linearGradient(
                Gradient(colors: [Aqua.metalLight, Aqua.metalDark]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            var generator = SeededGenerator(seed: 7)
            var y: CGFloat = 0
            while y < size.height {
                let alpha = Double.random(in: 0.0...0.10, using: &generator)
                let light = Bool.random(using: &generator)
                context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)),
                             with: .color((light ? Color.white : Color.black).opacity(alpha)))
                y += 1
            }
        }
    }
}

/// Fixed-seed randomness so the metal grain looks the same on every draw.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

/// The glossy "gel" capsule button.
struct GelButtonStyle: ButtonStyle {
    enum Kind { case primary, plain, danger }
    var kind: Kind = .plain
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let colors: [Color]
        let text: Color
        switch kind {
        case .primary: colors = [Aqua.blueLight, Aqua.blue, Aqua.blueDeep]; text = .white
        case .danger: colors = [Color(red: 1, green: 0.62, blue: 0.56), Aqua.danger, Color(red: 0.55, green: 0.08, blue: 0.06)]; text = .white
        case .plain: colors = [.white, Color(white: 0.90), Color(white: 0.78)]; text = Aqua.ink
        }
        return configuration.label
            .font(Aqua.font(compact ? 11 : 12.5, bold: kind != .plain))
            .foregroundStyle(text)
            .padding(.horizontal, compact ? 10 : 15)
            .padding(.vertical, compact ? 3.5 : 5.5)
            .background(
                ZStack {
                    // A plain dark capsule one point lower stands in for a drop shadow. (A real
                    // blurred shadow left faint marks at the rounded ends.)
                    Capsule().fill(Color.black.opacity(0.22)).offset(y: 1)
                    Capsule().fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
                    // The highlight that makes it read as a drop of gel: a lighter band over the top half.
                    GeometryReader { proxy in
                        Capsule()
                            .fill(LinearGradient(colors: [.white.opacity(0.85), .white.opacity(0.10)], startPoint: .top, endPoint: .bottom))
                            .frame(width: max(0, proxy.size.width - 8), height: proxy.size.height * 0.46)
                            .position(x: proxy.size.width / 2, y: proxy.size.height * 0.27)
                    }
                    // A whole-point line: a fractional width smears at the capsule's vertical ends.
                    Capsule().strokeBorder(Color.black.opacity(kind == .plain ? 0.30 : 0.38), lineWidth: 1)
                    if pressed { Capsule().fill(Color.black.opacity(0.14)) }
                }
            )
            .contentShape(Capsule())
    }
}

extension ButtonStyle where Self == GelButtonStyle {
    static var gel: GelButtonStyle { GelButtonStyle() }
    static var gelPrimary: GelButtonStyle { GelButtonStyle(kind: .primary) }
    static var gelDanger: GelButtonStyle { GelButtonStyle(kind: .danger) }
    static var gelSmall: GelButtonStyle { GelButtonStyle(compact: true) }
    static var gelSmallPrimary: GelButtonStyle { GelButtonStyle(kind: .primary, compact: true) }
}

/// The LCD strip: a dark recessed display with glowing segments, like a 2001 hi-fi.
struct LCDSegment: Identifiable {
    enum Tone { case calm, warn, alarm }
    let id = UUID()
    var value: String
    var label: String
    var tone: Tone = .calm
}

struct LCDStrip: View {
    var segments: [LCDSegment]
    var trailing: String? = nil
    var height: CGFloat = 34

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                if index > 0 {
                    Rectangle().fill(Aqua.lcdGreen.opacity(0.18)).frame(width: 1, height: height * 0.5).padding(.horizontal, 11)
                }
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(segment.value).font(Aqua.mono(height * 0.50, bold: true))
                    Text(segment.label).font(Aqua.mono(height * 0.28, bold: true)).opacity(0.78)
                }
                .foregroundStyle(color(segment.tone))
                .shadow(color: color(segment.tone).opacity(0.75), radius: 3.5)
            }
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing).font(Aqua.mono(height * 0.28, bold: true))
                    .foregroundStyle(Aqua.lcdGreen.opacity(0.62))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 13)
        .frame(height: height)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Aqua.lcdBackground)
                // Scanlines.
                Canvas { context, size in
                    var y: CGFloat = 0
                    while y < size.height {
                        context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(.black.opacity(0.28)))
                        y += 3
                    }
                }.clipShape(RoundedRectangle(cornerRadius: 6))
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(LinearGradient(colors: [.black.opacity(0.85), .white.opacity(0.35)], startPoint: .top, endPoint: .bottom), lineWidth: 1.2)
            }
        )
    }

    private func color(_ tone: LCDSegment.Tone) -> Color {
        switch tone {
        case .calm: return Aqua.lcdGreen
        case .warn: return Aqua.lcdAmber
        case .alarm: return Aqua.lcdRed
        }
    }
}

/// A small glass indicator lamp.
struct StatusLamp: View {
    var color: Color
    var size: CGFloat = 9

    var body: some View {
        Circle()
            .fill(RadialGradient(colors: [.white.opacity(0.95), color, color.opacity(0.75)],
                                 center: UnitPoint(x: 0.35, y: 0.28), startRadius: 0, endRadius: size * 0.75))
            .overlay(Circle().strokeBorder(.black.opacity(0.35), lineWidth: 0.6))
            .frame(width: size, height: size)
            .shadow(color: color.opacity(0.7), radius: 2.5)
    }
}

/// An inset white field with the soft inner shadow Aqua text boxes had.
struct AquaFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .font(Aqua.font(12.5))
            .foregroundStyle(Aqua.ink)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 4).fill(.white)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(
                        LinearGradient(colors: [Color(white: 0.45), Color(white: 0.72)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
                    .shadow(color: .black.opacity(0.10), radius: 0.5, x: 0, y: 1)
            )
    }
}

/// A titled group box with the etched Aqua border.
struct AquaBox<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title).font(Aqua.font(12, bold: true)).foregroundStyle(Aqua.ink)
            }
            content
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7).fill(.white.opacity(0.62))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.black.opacity(0.16), lineWidth: 1))
                .shadow(color: .white.opacity(0.9), radius: 0, x: 0, y: 1)
        )
    }
}

extension View {
    func aquaBody() -> some View { font(Aqua.font(12)).foregroundStyle(Aqua.inkSoft) }
}
