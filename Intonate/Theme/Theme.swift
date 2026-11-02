import SwiftUI

/// The look of a darkened hall: near-black velvet, brass, and warm light with little else.
enum Theme {
    static let ink = Color(red: 0.035, green: 0.028, blue: 0.055)
    static let velvet = Color(red: 0.16, green: 0.055, blue: 0.14)
    static let curtain = Color(red: 0.40, green: 0.085, blue: 0.16)
    static let brass = Color(red: 0.93, green: 0.74, blue: 0.42)
    static let candle = Color(red: 1.0, green: 0.93, blue: 0.76)
    static let parchment = Color(red: 0.90, green: 0.85, blue: 0.77)
    static let mutedText = Color(red: 0.66, green: 0.60, blue: 0.58)
    static let cool = Color(red: 0.50, green: 0.72, blue: 1.0)
    static let hairline = Color.white.opacity(0.09)

    static func display(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }

    static func eyebrow() -> Font {
        .system(size: 11, weight: .semibold, design: .serif)
    }

    /// Warm inside the in-tune line, cool outside it, matching the pitch trail on the waterfall.
    static func tuningColor(cents: Double?) -> Color {
        guard let cents else { return mutedText }
        return abs(cents) <= 25 ? candle : cool
    }
}

/// The balconies of a hall, seen from the stage: tiers of small warm lights over a dark gradient.
struct HallBackground: View {
    var body: some View {
        ZStack {
            Theme.ink
            RadialGradient(
                colors: [Theme.curtain.opacity(0.42), Theme.velvet.opacity(0.28), .clear],
                center: UnitPoint(x: 0.5, y: -0.12),
                startRadius: 10,
                endRadius: 560
            )
            Canvas { context, size in
                for tier in 0..<5 {
                    let depth = CGFloat(tier) / 4
                    let radius = size.width * (0.66 + depth * 0.72)
                    let center = CGPoint(x: size.width / 2, y: -radius + 62 + depth * 92)
                    let lights = 15 + tier * 4
                    for light in 0...lights {
                        let along = CGFloat(light) / CGFloat(lights)
                        let angle = CGFloat.pi / 2 + (along - 0.5) * 1.3
                        let point = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
                        let size = 2.2 - depth * 1.1
                        let rect = CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
                        let opacity = 0.55 - Double(depth) * 0.32
                        context.fill(Path(ellipseIn: rect), with: .color(Theme.candle.opacity(opacity)))
                        context.fill(
                            Path(ellipseIn: rect.insetBy(dx: -size * 1.3, dy: -size * 1.3)),
                            with: .color(Theme.brass.opacity(opacity * 0.14))
                        )
                    }
                }
            }
        }
        .ignoresSafeArea()
    }
}

struct DemoBadge: View {
    var body: some View {
        Text("DEMO VOICE")
            .font(.system(size: 9.5, weight: .bold, design: .serif))
            .tracking(1.4)
            .foregroundStyle(Theme.brass)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .overlay(Capsule().strokeBorder(Theme.brass.opacity(0.5), lineWidth: 0.75))
            .accessibilityLabel("Demo voice, synthesized audio")
            .accessibilityIdentifier("demoBadge")
    }
}
