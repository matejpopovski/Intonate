import IntonateDSP
import IntonateTraining
import SwiftUI

/// The live screen: spectrogram on top, and the note being sung under it.
struct StageView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let exercise: Exercise?

    @State private var session: TrainerSession?
    @State private var measuring: MeasurementRun?

    var body: some View {
        ZStack {
            Theme.ink.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                waterfall
                if let session {
                    StageReadoutView(session: session)
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .task { await begin() }
        .onDisappear { session?.stop() }
        .onChange(of: session?.phase) { _, phase in
            if case .finished(let report) = phase, let exercise {
                model.finish(exercise, report: report)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Button {
                session?.stop()
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Theme.parchment)
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Back to the programme")
            .accessibilityIdentifier("backToProgramme")
            VStack(alignment: .leading, spacing: 2) {
                Text(exercise?.title ?? Exercise.freeSinging.title)
                    .font(Theme.display(22))
                    .foregroundStyle(Theme.candle)
                Text("\(model.voice.displayName) voice")
                    .font(.system(size: 12.5, design: .serif))
                    .italic()
                    .foregroundStyle(Theme.mutedText)
            }
            Spacer()
            if model.input == .demo {
                DemoBadge()
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    @ViewBuilder private var waterfall: some View {
        if let session, let scene = session.scene {
            ZStack(alignment: .leading) {
                WaterfallView(renderer: session.renderer, scene: scene, monitor: session.monitor)
                NoteAxis(scene: scene)
            }
            .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 0.5) }
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 0.5) }
        } else if case .failed(let message)? = session?.phase {
            VStack(spacing: 14) {
                Text(message)
                    .font(Theme.display(17))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.parchment)
                Button("Use the demo voice") {
                    model.input = .demo
                    Task { await begin() }
                }
                .foregroundStyle(Theme.brass)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Color.clear
        }
    }

    private func begin() async {
        session?.stop()
        let monitor = model.options.measureSeconds == nil ? nil : PipelineMonitor()
        let session = TrainerSession(exercise: exercise, voice: model.voice, mode: model.input, monitor: monitor)
        self.session = session
        await session.start()
        if let seconds = model.options.measureSeconds {
            let run = MeasurementRun(session: session, seconds: seconds)
            measuring = run
            run.begin()
        }
    }
}

/// Names of the notes in play at the left edge. Their height never changes during a run, so SwiftUI
/// can draw them over the Metal view without any need to stay in step with it.
private struct NoteAxis: View {
    let scene: WaterfallScene

    private var labels: [Int] {
        if let timeline = scene.timeline {
            return Array(Set(timeline.notes.map(\.midi))).sorted()
        }
        let low = Int(ceil(scene.geometry.lowMidi))
        let high = Int(floor(scene.geometry.highMidi))
        return (low...high).filter { $0 % 12 == 0 }
    }

    var body: some View {
        GeometryReader { proxy in
            ForEach(labels, id: \.self) { midi in
                Text(NoteName(midi: midi).description)
                    .font(.system(size: 10.5, weight: .medium, design: .serif))
                    .foregroundStyle(Theme.parchment.opacity(0.75))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Theme.ink.opacity(0.55), in: Capsule())
                    .position(x: 22, y: (1 - scene.geometry.y(midi: Double(midi))) * proxy.size.height)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Everything under the waterfall. Split out so that its 30 Hz updates do not re-evaluate the Metal view.
private struct StageReadoutView: View {
    let session: TrainerSession

    var body: some View {
        let readout = session.readout
        VStack(spacing: 6) {
            ZStack {
                switch session.phase {
                case .countIn:
                    VStack(spacing: 0) {
                        Text("\(max(readout.beatsLeft, 1))")
                            .font(Theme.display(64))
                            .foregroundStyle(Theme.brass)
                            .contentTransition(.numericText())
                        Text("Starting on \(readout.target.map { NoteName(midi: $0.midi).description } ?? "")")
                            .font(Theme.display(15))
                            .italic()
                            .foregroundStyle(Theme.parchment.opacity(0.8))
                    }
                default:
                    VStack(spacing: 1) {
                        Text(readout.noteName ?? "–")
                            .font(Theme.display(64))
                            .monospacedDigit()
                            .foregroundStyle(readout.noteName == nil ? Theme.mutedText : Theme.candle)
                            .shadow(color: Theme.brass.opacity(readout.noteName == nil ? 0 : 0.4), radius: 16)
                            .accessibilityIdentifier("sungNote")
                        Text(centsText(readout.cents))
                            .font(.system(size: 15, design: .serif).monospacedDigit())
                            .foregroundStyle(Theme.tuningColor(cents: readout.cents))
                    }
                }
            }
            .frame(height: 104)

            CentsMeter(cents: readout.cents)
                .frame(height: 56)
                .padding(.horizontal, 44)

            footer(readout)
        }
        .padding(.horizontal, 24)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private func centsText(_ cents: Double?) -> String {
        guard let cents else { return "listening" }
        let value = Int(cents.rounded())
        return value > 0 ? "+\(value)¢" : value < 0 ? "\u{2212}\(-value)¢" : "0¢"
    }

    @ViewBuilder private func footer(_ readout: TrainerSession.Readout) -> some View {
        if readout.noteCount > 0 {
            VStack(spacing: 7) {
                HStack {
                    Text(readout.target.map { "Target \(NoteName(midi: $0.midi).description)" } ?? "")
                    Spacer()
                    Text(readout.noteNumber > 0 ? "Note \(readout.noteNumber) of \(readout.noteCount)" : "")
                }
                .font(.system(size: 13, design: .serif).monospacedDigit())
                .foregroundStyle(Theme.mutedText)
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.hairline)
                        Capsule().fill(Theme.brass).frame(width: proxy.size.width * readout.progress)
                    }
                }
                .frame(height: 2)
            }
        } else {
            Text("Free stage: nothing is scored here.")
                .font(.system(size: 13, design: .serif))
                .italic()
                .foregroundStyle(Theme.mutedText)
        }
    }
}
