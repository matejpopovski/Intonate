import IntonateDSP
import IntonateSynth
import IntonateTraining
import Metal
import Observation
import UIKit

/// One run at the stage: builds the input and the analysis for it, and tracks where the exercise is.
@MainActor
@Observable
final class TrainerSession {
    enum Phase: Equatable {
        case preparing
        case countIn
        case singing
        case freeSinging
        case finished(PerformanceReport)
        case failed(String)
    }

    struct Readout: Equatable {
        var noteName: String?
        var cents: Double?
        var target: TimedNote?
        var noteNumber = 0
        var noteCount = 0
        var beatsLeft = 0
        var progress = 0.0
    }

    private(set) var phase = Phase.preparing
    private(set) var readout = Readout()
    private(set) var scene: WaterfallScene?
    private(set) var renderer: WaterfallRenderer?
    private(set) var rendererSetupMilliseconds: Double?

    let exercise: Exercise?
    let monitor: PipelineMonitor?

    private let voice: VoiceRange
    private let mode: InputMode
    private var timeline: ExerciseTimeline?
    private var engine: AnalysisEngine?
    private var input: AudioInput?
    private var leadIn = 0.0
    private var secondsPerBeat = 0.75
    private var ticker: Task<Void, Never>?

    private static let countInBeats = 4
    private static let demoRate = 44_100.0

    init(
        exercise: Exercise?,
        voice: VoiceRange,
        mode: InputMode,
        monitor: PipelineMonitor? = nil
    ) {
        self.exercise = exercise
        self.voice = voice
        self.mode = mode
        self.monitor = monitor
    }

    func start() async {
        let timeline = exercise.map { ExerciseTimeline(exercise: $0, tonicMidi: voice.tonicMidi) }
        self.timeline = timeline
        secondsPerBeat = exercise.map { 60 / $0.tempo } ?? 0.75
        leadIn = timeline == nil ? 0 : Double(Self.countInBeats) * secondsPerBeat

        do {
            let (input, sampleRate) = try await makeInput(timeline: timeline)
            let configuration = AnalysisConfiguration(sampleRate: sampleRate)
            let engine = AnalysisEngine(configuration: configuration, monitor: monitor)
            let range = WaterfallGeometry.range(for: timeline)
            scene = WaterfallScene(
                geometry: WaterfallGeometry(lowMidi: range.low, highMidi: range.high),
                timeline: timeline,
                leadIn: leadIn
            )
            // Built before the audio starts: compiling shaders on a cold device can hold the main
            // thread for a noticeable moment, and audio running meanwhile would pile up behind it.
            let began = mach_continuous_time()
            if let device = MTLCreateSystemDefaultDevice() {
                renderer = try? WaterfallRenderer(
                    device: device,
                    pixelFormat: WaterfallRenderer.pixelFormat,
                    feed: engine.feed
                )
            }
            rendererSetupMilliseconds = HostClock.milliseconds(from: began, to: mach_continuous_time())
            engine.start(plan: AnalysisEngine.Plan(timeline: timeline, leadIn: leadIn))
            try input.start(writingTo: engine.ring)
            self.input = input
            self.engine = engine
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }

        UIApplication.shared.isIdleTimerDisabled = true
        phase = timeline == nil ? .freeSinging : .countIn
        if let first = timeline?.notes.first, let timeline {
            input?.setReferenceTone(timeline.frequency(of: first))
        }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    func stop() {
        ticker?.cancel()
        ticker = nil
        input?.setReferenceTone(nil)
        input?.stop()
        engine?.stop()
        input = nil
        UIApplication.shared.isIdleTimerDisabled = false
    }

    var droppedSamples: UInt64 {
        engine?.ring.droppedSamples ?? 0
    }

    private func makeInput(timeline: ExerciseTimeline?) async throws -> (AudioInput, Double) {
        switch mode {
        case .microphone:
            let rate = try await MicrophoneInput.prepareSession()
            return (MicrophoneInput(), rate)
        case .demo:
            let script = timeline ?? ExerciseTimeline(exercise: .freeSinging, tonicMidi: voice.tonicMidi)
            let input = DemoInput(
                timeline: script,
                leadIn: leadIn,
                sampleRate: Self.demoRate,
                loops: timeline == nil
            )
            return (input, Self.demoRate)
        }
    }

    private func tick() {
        guard let engine else { return }
        let snapshot = engine.snapshot

        var next = readout
        let exerciseTime = snapshot.streamTime - leadIn
        if let frequency = snapshot.frame?.frequency {
            let midi = Tuning.standard.midi(frequency: frequency)
            next.noteName = NoteName(midi: Int(midi.rounded())).description
            next.cents = (midi - midi.rounded()) * 100
        } else {
            next.noteName = nil
            next.cents = nil
        }

        if let timeline {
            next.noteCount = timeline.notes.count
            next.progress = min(1, max(0, exerciseTime / timeline.duration))
            if exerciseTime < 0 {
                next.beatsLeft = Int(ceil(-exerciseTime / secondsPerBeat))
                next.target = timeline.notes.first
            } else {
                next.beatsLeft = 0
                if phase == .countIn {
                    phase = .singing
                    input?.setReferenceTone(nil)
                }
                if let note = timeline.note(at: exerciseTime) {
                    next.target = note
                    next.noteNumber = note.index + 1
                }
            }
            if let target = next.target, let frequency = snapshot.frame?.frequency {
                next.cents = cents(frequency, relativeTo: timeline.frequency(of: target))
            }
        }
        readout = next

        if let report = snapshot.report {
            stop()
            phase = .finished(report)
        }
    }
}

extension Exercise {
    /// What the demo voice sings on the free stage: a phrase with leaps, to give the trail some shape.
    static let freeSinging = Exercise(
        id: "free",
        numeral: "",
        title: "Free Stage",
        summary: "No score. Sing anything and watch it.",
        tempo: 84,
        steps: [0, 4, 7, 12, 11, 7, 9, 5, 4, 2, 0].map { Step($0, beats: 2) }
    )
}
