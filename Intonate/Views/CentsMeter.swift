import SwiftUI

/// An arc from 50 cents flat to 50 cents sharp, shaped like a conductor's beat. A needle is easier
/// to read at a glance while singing than a number that changes every frame.
struct CentsMeter: View {
    let cents: Double?

    private static let span = 1.05

    private func angle(_ value: Double) -> Double {
        -Double.pi / 2 + max(-1, min(1, value / 50)) * Self.span
    }

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height * 2.1)
            let radius = size.height * 1.86

            func point(_ value: Double, _ offset: CGFloat) -> CGPoint {
                let theta = angle(value)
                return CGPoint(
                    x: center.x + cos(theta) * (radius + offset),
                    y: center.y + sin(theta) * (radius + offset)
                )
            }

            var inTune = Path()
            inTune.addArc(
                center: center,
                radius: radius,
                startAngle: .radians(angle(-25)),
                endAngle: .radians(angle(25)),
                clockwise: false
            )
            context.stroke(
                inTune,
                with: .color(Theme.brass.opacity(0.75)),
                style: StrokeStyle(lineWidth: 3, lineCap: .round)
            )

            for tick in stride(from: -50, through: 50, by: 10) {
                var mark = Path()
                let isMajor = tick % 50 == 0
                mark.move(to: point(Double(tick), isMajor ? -9 : -6))
                mark.addLine(to: point(Double(tick), -2))
                context.stroke(
                    mark,
                    with: .color(Theme.parchment.opacity(isMajor ? 0.6 : 0.3)),
                    lineWidth: isMajor ? 1.3 : 0.8
                )
            }

            guard let cents else { return }
            let color = Theme.tuningColor(cents: cents)
            var needle = Path()
            needle.move(to: point(cents, -26))
            needle.addLine(to: point(cents, 9))
            context.drawLayer { layer in
                layer.addFilter(.shadow(color: color.opacity(0.9), radius: 7))
                layer.stroke(needle, with: .color(color), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
            }
        }
        .animation(.linear(duration: 0.05), value: cents)
        .accessibilityElement()
        .accessibilityLabel("Tuning")
        .accessibilityValue(cents.map { "\(Int($0.rounded())) cents" } ?? "no pitch")
    }
}
