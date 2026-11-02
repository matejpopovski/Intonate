import Foundation
import IntonateDSP
import IntonateSynth

/// A latency figure in audio time. It counts samples and not wall-clock time, so it is a property of
/// the algorithm and its parameters and comes out the same on any machine. Capture, scheduling and
/// display delays are additional and are reported separately from a running app.
struct LatencyRow: Encodable {
    let label: String
    let transitions: Int
    let missed: Int
    let p50Ms: Double
    let p95Ms: Double
    let maxMs: Double
}

struct WindowRow: Encodable {
    let windowMs: Double
    let windowSamples: Int
    let stepLatency: LatencyRow
    let accuracy: ConditionResult
    let accuracyAt20dB: ConditionResult
}

struct LatencyReport: Encodable {
    let host: HostInfo
    let definition: String
    let pipeline: PipelineFacts
    let noteToNote: [LatencyRow]
    let fromSilence: [LatencyRow]
    let windowSweep: [WindowRow]
}

struct PipelineFacts: Encodable {
    let sampleRate: Double
    let requiredSamples: Int
    let pitchHopSamples: Int
    let medianFrames: Int
    let onsetFrames: Int
}

/// Samples from the change to the first frame that is within 50 cents of the new note and stays
/// there for three more frames. Nil if that never happens.
private func stepLatency(
    configuration: AnalysisConfiguration,
    signal: [Float],
    changeSample: Int,
    target: Double
) -> Int? {
    let pipeline = AnalysisPipeline(configuration: configuration)
    var emissions: [(sample: Int64, frame: PitchFrame)] = []
    signal.withUnsafeBufferPointer { buffer in
        var offset = 0
        while offset < buffer.count {
            let count = min(256, buffer.count - offset)
            pipeline.process(
                UnsafeBufferPointer(rebasing: buffer[offset..<(offset + count)]),
                onPitch: { frame in emissions.append((pipeline.sampleCount, frame)) },
                onColumn: { _ in }
            )
            offset += count
        }
    }
    let after = emissions.filter { $0.sample > Int64(changeSample) }
    func onTarget(_ index: Int) -> Bool {
        guard index < after.count, let frequency = after[index].frame.frequency else { return false }
        return abs(cents(frequency, relativeTo: target)) <= 50
    }
    for index in after.indices where (0..<4).allSatisfy({ onTarget(index + $0) }) {
        return Int(after[index].sample) - changeSample
    }
    return nil
}

private func latencyRow(label: String, samples: [Int?], sampleRate: Double) -> LatencyRow {
    let measured = samples.compactMap { $0 }.map { Double($0) / sampleRate * 1_000 }.sorted()
    return LatencyRow(
        label: label,
        transitions: samples.count,
        missed: samples.count - measured.count,
        p50Ms: rounded(percentile(measured, 0.5), 2),
        p95Ms: rounded(percentile(measured, 0.95), 2),
        maxMs: rounded(measured.last ?? .nan, 2)
    )
}

private let startNotes = Array(stride(from: 43, through: 76, by: 3))

private func noteToNote(
    configuration: AnalysisConfiguration,
    interval: Int,
    timbre: Timbre,
    snr: Double
) -> [Int?] {
    let rate = configuration.sampleRate
    // Both notes have to be inside the C2 to C6 range the detector is measured on.
    let starts = startNotes.filter { (36...84).contains($0 + interval) }
    let outcomes = parallelMap(starts.count) { index -> [Int?] in
        let midi = starts[index]
        var rng = SplitMix64(seed: UInt64(midi) &* 7 &+ UInt64(bitPattern: Int64(interval &+ 100)))
        return (0..<8).map { _ in
            // A random onset phase against the hop grid, so the figure is not one lucky alignment.
            let change = 0.3 + rng.unit() * 0.02
            let first = Tuning.standard.frequency(midi: Double(midi))
            let second = Tuning.standard.frequency(midi: Double(midi + interval))
            let clean = VoiceSynth.clip(
                contour: .step(from: first, to: second, at: change),
                duration: 0.55,
                sampleRate: rate,
                timbre: timbre,
                seed: rng.next()
            )
            let signal = Signal.mix(clean, snrDB: snr, kind: .white, rng: &rng)
            return stepLatency(
                configuration: configuration,
                signal: signal,
                changeSample: Int(change * rate),
                target: second
            )
        }
    }
    return outcomes.flatMap { $0 }
}

private func fromSilence(configuration: AnalysisConfiguration, timbre: Timbre, noiseDB: Double) -> [Int?] {
    let rate = configuration.sampleRate
    let outcomes = parallelMap(startNotes.count) { index -> [Int?] in
        let midi = startNotes[index]
        var rng = SplitMix64(seed: UInt64(midi) &* 13)
        return (0..<8).map { _ in
            let change = 0.3 + rng.unit() * 0.02
            let frequency = Tuning.standard.frequency(midi: Double(midi))
            let changeSample = Int(change * rate)
            let voice = VoiceSynth.clip(
                contour: .constant(frequency),
                duration: 0.3,
                sampleRate: rate,
                timbre: timbre,
                seed: rng.next()
            )
            var signal = Signal.noise(kind: .white, count: changeSample + voice.count, rng: &rng)
            Signal.normalize(&signal, levelDB: noiseDB)
            for index in voice.indices {
                signal[changeSample + index] += voice[index]
            }
            return stepLatency(
                configuration: configuration,
                signal: signal,
                changeSample: changeSample,
                target: frequency
            )
        }
    }
    return outcomes.flatMap { $0 }
}

func runLatency(output: URL) throws {
    let configuration = AnalysisConfiguration()
    let rate = configuration.sampleRate

    print("note to note")
    let intervals: [(String, Int)] = [
        ("semitone up", 1), ("semitone down", -1), ("whole tone up", 2), ("fifth up", 7), ("fifth down", -7),
        ("octave up", 12), ("octave down", -12),
    ]
    let noteRows = intervals.map { name, interval in
        latencyRow(
            label: "\(name), vowelAh, 30 dB SNR",
            samples: noteToNote(configuration: configuration, interval: interval, timbre: .vowelAh, snr: 30),
            sampleRate: rate
        )
    }

    print("from silence")
    let silenceRows = [Timbre.vowelAh, .bright].map { timbre in
        latencyRow(
            label: "\(timbre.rawValue), noise floor at -70 dBFS",
            samples: fromSilence(configuration: configuration, timbre: timbre, noiseDB: -70),
            sampleRate: rate
        )
    }

    print("window sweep")
    let windows = [512, 768, 1_024, 1_536, 2_048]
    let windowRows = windows.map { samples -> WindowRow in
        let yin = YINConfiguration(windowLength: samples)
        var sweep = AnalysisConfiguration(yin: yin)
        sweep.pitchHop = configuration.pitchHop
        let factory: @Sendable () -> FrameDetector = { YINFrameDetector(configuration: yin) }
        let steps = [2, 7, -7, 12].flatMap { interval in
            noteToNote(configuration: sweep, interval: interval, timbre: .vowelAh, snr: 30)
        }
        return WindowRow(
            windowMs: rounded(Double(samples) / rate * 1_000, 1),
            windowSamples: samples,
            stepLatency: latencyRow(label: "mixed intervals, vowelAh, 30 dB SNR", samples: steps, sampleRate: rate),
            accuracy: measure(Condition(), seed: 31, makeDetector: factory).summary(label: "clean vowelAh"),
            accuracyAt20dB: measure(Condition(snrDB: 20), seed: 32, makeDetector: factory)
                .summary(label: "20 dB white")
        )
    }

    try writeJSON(
        LatencyReport(
            host: .current(note: "latency here is in audio time and does not depend on the machine"),
            definition:
                "Samples from the note change to the emission of the first tracker frame that is within 50 cents "
                + "of the new note and stays there for three more frames. Excludes capture, scheduling and display.",
            pipeline: PipelineFacts(
                sampleRate: rate,
                requiredSamples: configuration.yin.requiredSamples,
                pitchHopSamples: configuration.pitchHop,
                medianFrames: configuration.tracker.medianFrames,
                onsetFrames: configuration.tracker.onsetFrames
            ),
            noteToNote: noteRows,
            fromSilence: silenceRows,
            windowSweep: windowRows
        ),
        to: output.appendingPathComponent("latency.json")
    )
}
