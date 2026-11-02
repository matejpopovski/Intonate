import IntonateDSP
import IntonateTraining
import SwiftUI

/// The notices, printed the morning after: the score, the habit, and each note in the order sung.
struct ReviewView: View {
    @Environment(AppModel.self) private var model

    let exercise: Exercise
    let report: PerformanceReport

    var body: some View {
        ZStack {
            HallBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    summary
                    IntonationChart(notes: report.notes)
                        .frame(height: 216)
                    measures
                    actions
                }
                .padding(.horizontal, 24)
                .padding(.top, 72)
                .padding(.bottom, 32)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("NOTICES · \(exercise.title.uppercased())")
                .font(Theme.eyebrow())
                .tracking(2)
                .foregroundStyle(Theme.mutedText)
            HStack(alignment: .lastTextBaseline, spacing: 6) {
                Text("\(Int(report.score.rounded()))")
                    .font(Theme.display(96))
                    .foregroundStyle(Theme.candle)
                    .shadow(color: Theme.brass.opacity(0.5), radius: 24)
                    .accessibilityIdentifier("finalScore")
                Text("of 100")
                    .font(Theme.display(18))
                    .italic()
                    .foregroundStyle(Theme.mutedText)
            }
            if model.input == .demo {
                DemoBadge().padding(.top, 2)
            }
        }
    }

    private var summary: some View {
        Text(Self.verdict(report))
            .font(Theme.display(18))
            .foregroundStyle(Theme.parchment)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var measures: some View {
        HStack(spacing: 0) {
            Measure(label: "In tune", value: "\(Int((report.inTuneFraction * 100).rounded()))%")
            Measure(label: "Mean error", value: report.meanAbsoluteCents.map { "\(Int($0.rounded()))¢" } ?? "–")
            Measure(
                label: "Tendency",
                value: report.tendencyCents.map { "\($0 > 0 ? "+" : "\u{2212}")\(Int(abs($0).rounded()))¢" } ?? "–"
            )
        }
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Button {
                model.path = [.stage(exercise)]
            } label: {
                Text("Sing again")
                    .font(Theme.display(17, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Theme.brass, in: Capsule())
            }
            .accessibilityIdentifier("singAgain")
            Button {
                model.path = []
            } label: {
                Text("Programme")
                    .font(Theme.display(17))
                    .foregroundStyle(Theme.parchment)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .overlay(Capsule().strokeBorder(Theme.parchment.opacity(0.35), lineWidth: 0.75))
            }
            .accessibilityIdentifier("backToProgrammeFromReview")
        }
        .buttonStyle(.plain)
    }

    /// One sentence the singer can act on, not a restatement of the numbers.
    static func verdict(_ report: PerformanceReport) -> String {
        guard let tendency = report.tendencyCents else {
            return "Nothing was heard. Check that the voice reaches the microphone."
        }
        let sung = report.notes.filter { $0.meanCents != nil }
        let worst = sung.max { ($0.meanAbsoluteCents ?? 0) < ($1.meanAbsoluteCents ?? 0) }
        let habit: String
        if abs(tendency) < 5 {
            habit = "Centred on the pitch overall"
        } else {
            habit = "Running \(Int(abs(tendency).rounded())) cents \(tendency < 0 ? "flat" : "sharp") overall"
        }
        guard let worst, let error = worst.meanCents else { return habit + "." }
        let direction = error < 0 ? "flat" : "sharp"
        let name = NoteName(midi: worst.note.midi)
        return "\(habit). The \(name) at note \(worst.note.index + 1) sat furthest off, "
            + "\(Int(abs(error).rounded())) cents \(direction)."
    }
}

private struct Measure: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(Theme.display(25).monospacedDigit())
                .foregroundStyle(Theme.candle)
            Text(label)
                .font(.system(size: 12, design: .serif))
                .foregroundStyle(Theme.mutedText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Each note as a stem from the true pitch, flat below the line and sharp above it, in cents.
private struct IntonationChart: View {
    let notes: [NoteResult]

    private static let limit = 50.0

    var body: some View {
        Canvas { context, size in
            let top: CGFloat = 16
            let bottom = size.height - 28
            let middle = (top + bottom) / 2
            let scale = (bottom - top) / 2 / Self.limit
            let left: CGFloat = 32

            let band = CGRect(x: left, y: middle - 25 * scale, width: size.width - left, height: 50 * scale)
            context.fill(Path(band), with: .color(Theme.brass.opacity(0.09)))

            func label(_ text: String, y: CGFloat) {
                context.draw(
                    Text(text).font(.system(size: 10, design: .serif)).foregroundStyle(Theme.mutedText),
                    at: CGPoint(x: 0, y: y),
                    anchor: .leading
                )
            }
            label("+25", y: middle - 25 * scale)
            label("0", y: middle)
            label("\u{2212}25", y: middle + 25 * scale)

            var zero = Path()
            zero.move(to: CGPoint(x: left, y: middle))
            zero.addLine(to: CGPoint(x: size.width, y: middle))
            context.stroke(zero, with: .color(Theme.brass.opacity(0.65)), lineWidth: 0.75)

            let step = (size.width - left) / CGFloat(max(notes.count, 1))
            for (index, result) in notes.enumerated() {
                let x = left + step * (CGFloat(index) + 0.5)
                context.draw(
                    Text(NoteName(midi: result.note.midi).description)
                        .font(.system(size: notes.count > 9 ? 8.5 : 10, design: .serif))
                        .foregroundStyle(Theme.mutedText),
                    at: CGPoint(x: x, y: size.height - 9)
                )
                guard let cents = result.meanCents else { continue }
                let clamped = max(-Self.limit, min(Self.limit, cents))
                let y = middle - CGFloat(clamped) * scale
                let color = Theme.tuningColor(cents: cents)
                var stem = Path()
                stem.move(to: CGPoint(x: x, y: middle))
                stem.addLine(to: CGPoint(x: x, y: y))
                context.stroke(stem, with: .color(color.opacity(0.6)), lineWidth: 1.2)
                let dot = CGRect(x: x - 4.5, y: y - 4.5, width: 9, height: 9)
                context.fill(Path(ellipseIn: dot.insetBy(dx: -4, dy: -4)), with: .color(color.opacity(0.14)))
                context.fill(Path(ellipseIn: dot), with: .color(color))
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Mean pitch error of each note")
        .accessibilityValue(
            notes.map { result in
                "\(NoteName(midi: result.note.midi)) \(result.meanCents.map { "\(Int($0.rounded())) cents" } ?? "not sung")"
            }
            .joined(separator: ", ")
        )
    }
}
