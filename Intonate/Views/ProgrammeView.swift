import IntonateDSP
import IntonateTraining
import SwiftUI

/// The first screen, laid out like the programme handed out at a recital.
struct ProgrammeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            HallBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    masthead
                    voicePicker.padding(.top, 26)
                    Text("TONIGHT'S PROGRAMME")
                        .font(Theme.eyebrow())
                        .tracking(2.2)
                        .foregroundStyle(Theme.mutedText)
                        .padding(.top, 30)
                        .padding(.bottom, 4)
                    ForEach(Exercise.programme) { exercise in
                        NavigationLink(value: Route.stage(exercise)) {
                            ProgrammeRow(exercise: exercise, voice: model.voice, best: model.bestScore(for: exercise))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("exercise-\(exercise.id)")
                    }
                    freeStageRow
                    inputFooter.padding(.top, 22)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    private var masthead: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Intonate")
                .font(Theme.display(52))
                .foregroundStyle(Theme.candle)
                .shadow(color: Theme.brass.opacity(0.45), radius: 20)
            Text("A pitch trainer for singers")
                .font(Theme.display(17))
                .italic()
                .foregroundStyle(Theme.parchment.opacity(0.8))
        }
        .padding(.top, 84)
    }

    private var voicePicker: some View {
        @Bindable var model = model
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(VoiceRange.allCases) { voice in
                    Button {
                        model.voice = voice
                    } label: {
                        Text(voice.displayName)
                            .font(Theme.display(14, weight: model.voice == voice ? .semibold : .regular))
                            .foregroundStyle(model.voice == voice ? Theme.ink : Theme.parchment)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 7)
                            .background(model.voice == voice ? Theme.brass : Color.white.opacity(0.06), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("voice-\(voice.rawValue)")
                    .accessibilityAddTraits(model.voice == voice ? .isSelected : [])
                }
            }
        }
        .scrollClipDisabled()
    }

    private var freeStageRow: some View {
        NavigationLink(value: Route.stage(nil)) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text("∞")
                    .font(Theme.display(17))
                    .foregroundStyle(Theme.brass)
                    .frame(width: 30, alignment: .leading)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Free Stage")
                        .font(Theme.display(21))
                        .foregroundStyle(Theme.candle)
                    Text("No score. Sing anything and watch it.")
                        .font(.system(size: 13.5, design: .serif))
                        .foregroundStyle(Theme.mutedText)
                }
                Spacer()
            }
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("exercise-free")
    }

    @ViewBuilder private var inputFooter: some View {
        @Bindable var model = model
        if AppModel.microphoneAvailable {
            Picker("Input", selection: $model.input) {
                Text("Microphone").tag(InputMode.microphone)
                Text("Demo voice").tag(InputMode.demo)
            }
            .pickerStyle(.segmented)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                DemoBadge()
                Text("The Simulator has no dependable microphone, so a synthesized voice sings here.")
                    .font(.system(size: 12.5, design: .serif))
                    .foregroundStyle(Theme.mutedText)
            }
        }
    }
}

private struct ProgrammeRow: View {
    let exercise: Exercise
    let voice: VoiceRange
    let best: Double?

    private var length: String {
        let seconds = ExerciseTimeline(exercise: exercise, tonicMidi: voice.tonicMidi).duration
        return "\(Int(seconds.rounded())) s"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text(exercise.numeral)
                    .font(Theme.display(17))
                    .foregroundStyle(Theme.brass)
                    .frame(width: 30, alignment: .leading)
                VStack(alignment: .leading, spacing: 3) {
                    Text(exercise.title)
                        .font(Theme.display(21))
                        .foregroundStyle(Theme.candle)
                    Text(exercise.summary)
                        .font(.system(size: 13.5, design: .serif))
                        .foregroundStyle(Theme.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(length)
                        .font(.system(size: 12.5, design: .serif).monospacedDigit())
                        .foregroundStyle(Theme.mutedText)
                    if let best {
                        Text("\(Int(best.rounded()))")
                            .font(Theme.display(17).monospacedDigit())
                            .foregroundStyle(Theme.brass)
                            .accessibilityLabel("Best score \(Int(best.rounded()))")
                    }
                }
            }
            .padding(.vertical, 13)
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
        }
        .contentShape(Rectangle())
    }
}
