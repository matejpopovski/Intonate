import Foundation
import IntonateDSP
import IntonateSynth

/// One signal condition. Every condition covers C2 to C6 in semitones, each note detuned by a random
/// amount inside ±50 cents so that no result can lean on an exact integer period.
struct Condition: Sendable {
    var timbre: Timbre = .vowelAh
    var snrDB: Double?
    var noise: NoiseKind = .white
    var vibratoDepthCents: Double = 0
    var sampleRate: Double = 44_100
    var midiRange: ClosedRange<Int> = 36...84
}

let vibratoRate = 5.5
let repeatsPerNote = 16
let framesPerClip = 8

/// Runs a fresh detector per note, so that the cost of the grid spreads across worker threads.
func measure(
    _ condition: Condition,
    seed: UInt64,
    makeDetector: @escaping @Sendable () -> FrameDetector
) -> Tally {
    let notes = Array(condition.midiRange)
    let tallies = parallelMap(notes.count) { index in
        let midi = notes[index]
        var tally = Tally()
        let detector = makeDetector()
        var rng = SplitMix64(seed: seed &+ UInt64(midi) &* 1_000_003)
        let length = detector.requiredSamples
        let spacing = Int(condition.sampleRate * 0.013)
        let clipSeconds = Double(length + spacing * framesPerClip + 8) / condition.sampleRate

        for _ in 0..<repeatsPerNote {
            let center = Tuning.standard.frequency(midi: Double(midi) + (rng.unit() - 0.5))
            let contour: F0Contour
            if condition.vibratoDepthCents > 0 {
                contour = .vibrato(
                    center: center,
                    rate: vibratoRate,
                    depthCents: condition.vibratoDepthCents,
                    phase: rng.unit() * 2 * .pi
                )
            } else {
                contour = .constant(center)
            }
            var clip = VoiceSynth.clip(
                contour: contour,
                duration: clipSeconds,
                sampleRate: condition.sampleRate,
                timbre: condition.timbre,
                seed: rng.next()
            )
            if let snr = condition.snrDB {
                clip = Signal.mix(clip, snrDB: snr, kind: condition.noise, rng: &rng)
            }

            clip.withUnsafeBufferPointer { buffer in
                for frameIndex in 0..<framesPerClip {
                    let start = frameIndex * spacing
                    let frame = UnsafeBufferPointer(rebasing: buffer[start..<(start + length)])
                    if let result = detector.detect(frame) {
                        let time =
                            (Double(start) + detector.centerOffset(forFrequency: result.frequency))
                            / condition.sampleRate
                        tally.add(estimate: result.frequency, isVoiced: result.isVoiced, truth: contour.frequency(time))
                    } else {
                        tally.add(estimate: nil, isVoiced: false, truth: center)
                    }
                }
            }
        }
        return tally
    }
    return tallies.reduce(into: Tally()) { $0.merge($1) }
}

/// The same grid through the whole pipeline, so that voicing decisions and the median count. Each clip
/// is a sustained note; the first 120 ms are skipped so that onset behaviour stays in `latency.json`.
func measureTracker(
    _ condition: Condition,
    seed: UInt64,
    tracker: PitchTrackerConfiguration = PitchTrackerConfiguration()
) -> Tally {
    let notes = Array(condition.midiRange)
    let tallies = parallelMap(notes.count) { index in
        let midi = notes[index]
        var tally = Tally()
        var rng = SplitMix64(seed: seed &+ UInt64(midi) &* 1_000_033)
        let configuration = AnalysisConfiguration(sampleRate: condition.sampleRate, tracker: tracker)
        let pipeline = AnalysisPipeline(configuration: configuration)

        for _ in 0..<4 {
            let center = Tuning.standard.frequency(midi: Double(midi) + (rng.unit() - 0.5))
            let contour: F0Contour =
                condition.vibratoDepthCents > 0
                ? .vibrato(
                    center: center,
                    rate: vibratoRate,
                    depthCents: condition.vibratoDepthCents,
                    phase: rng.unit() * 2 * .pi
                )
                : .constant(center)
            var clip = VoiceSynth.clip(
                contour: contour,
                duration: 0.4,
                sampleRate: condition.sampleRate,
                timbre: condition.timbre,
                seed: rng.next()
            )
            if let snr = condition.snrDB {
                clip = Signal.mix(clip, snrDB: snr, kind: condition.noise, rng: &rng)
            }
            pipeline.reset()
            clip.withUnsafeBufferPointer { buffer in
                pipeline.process(
                    buffer,
                    onPitch: { frame in
                        guard frame.time > 0.12 else { return }
                        tally.add(
                            estimate: frame.frequency,
                            isVoiced: frame.frequency != nil,
                            truth: contour.frequency(frame.time)
                        )
                    },
                    onColumn: { _ in }
                )
            }
        }
        return tally
    }
    return tallies.reduce(into: Tally()) { $0.merge($1) }
}

struct AccuracyReport: Encodable {
    let host: HostInfo
    let grid: String
    let trackerByTimbre: [ConditionResult]
    let trackerBySNRWhite: [ConditionResult]
    let trackerBySNRPink: [ConditionResult]
    let trackerByVibrato: [ConditionResult]
    let trackerNote: String
    let byTimbre: [ConditionResult]
    let bySNRWhite: [ConditionResult]
    let bySNRPink: [ConditionResult]
    let byVibrato: [ConditionResult]
    let byRegister: [ConditionResult]
    let byRegisterAt20dB: [ConditionResult]
    let at48kHz: ConditionResult
}

struct ComparisonReport: Encodable {
    let host: HostInfo
    let conditions: String
    let detectorsClean: [ConditionResult]
    let detectorsAt20dB: [ConditionResult]
    let detectorsAt5dB: [ConditionResult]
    let detectorsBrightClean: [ConditionResult]
    let detectorsWeakFundamental: [ConditionResult]
}

struct ThresholdRow: Encodable {
    let voicingThreshold: Double
    let voicedRateBySNR: [String: Double]
    let rawPitchAccuracyBySNR: [String: Double]
    let octaveErrorRateBySNR: [String: Double]
    let falseVoicedWhiteNoise: Double
    let falseVoicedPinkNoise: Double
}

struct ThresholdReport: Encodable {
    let host: HostInfo
    let note: String
    let rows: [ThresholdRow]
}

func runAccuracy(output: URL) throws {
    let yinFactory: @Sendable () -> FrameDetector = { YINFrameDetector(configuration: YINConfiguration()) }

    print("timbres")
    let byTimbre = Timbre.allCases.map { timbre in
        measure(Condition(timbre: timbre), seed: 1, makeDetector: yinFactory).summary(label: timbre.rawValue)
    }

    print("SNR")
    let snrs: [Double] = [40, 30, 20, 15, 10, 5, 0]
    let bySNRWhite = snrs.map { snr in
        measure(Condition(snrDB: snr), seed: 2, makeDetector: yinFactory).summary(label: "\(Int(snr)) dB white")
    }
    let bySNRPink = snrs.map { snr in
        measure(Condition(snrDB: snr, noise: .pink), seed: 3, makeDetector: yinFactory)
            .summary(label: "\(Int(snr)) dB pink")
    }

    print("vibrato")
    let byVibrato = [25.0, 50, 100].map { depth in
        measure(Condition(vibratoDepthCents: depth), seed: 4, makeDetector: yinFactory)
            .summary(label: "±\(Int(depth)) cents at \(vibratoRate) Hz")
    }

    print("registers")
    let registers: [(String, ClosedRange<Int>)] = [
        ("C2-B2", 36...47), ("C3-B3", 48...59), ("C4-B4", 60...71), ("C5-C6", 72...84),
    ]
    let byRegister = registers.map { name, range in
        measure(Condition(midiRange: range), seed: 5, makeDetector: yinFactory).summary(label: name)
    }
    let byRegisterAt20dB = registers.map { name, range in
        measure(Condition(snrDB: 20, midiRange: range), seed: 6, makeDetector: yinFactory).summary(label: name)
    }

    print("tracker")
    let trackerByTimbre = Timbre.allCases.map { timbre in
        measureTracker(Condition(timbre: timbre), seed: 51).summary(label: timbre.rawValue)
    }
    let trackerBySNRWhite = snrs.map { snr in
        measureTracker(Condition(snrDB: snr), seed: 52).summary(label: "\(Int(snr)) dB white")
    }
    let trackerBySNRPink = snrs.map { snr in
        measureTracker(Condition(snrDB: snr, noise: .pink), seed: 53).summary(label: "\(Int(snr)) dB pink")
    }
    let trackerByVibrato = [25.0, 50, 100].map { depth in
        measureTracker(Condition(vibratoDepthCents: depth), seed: 54)
            .summary(label: "±\(Int(depth)) cents at \(vibratoRate) Hz")
    }

    let at48: @Sendable () -> FrameDetector = {
        YINFrameDetector(configuration: YINConfiguration(sampleRate: 48_000))
    }
    let at48kHz = measure(Condition(sampleRate: 48_000), seed: 7, makeDetector: at48).summary(label: "48 kHz vowelAh")

    let grid =
        "MIDI 36-84, \(repeatsPerNote) clips per note, \(framesPerClip) frames per clip, "
        + "random detune within ±50 cents, YIN defaults, 44.1 kHz unless stated"
    try writeJSON(
        AccuracyReport(
            host: .current(note: "accuracy figures are machine independent; signals are seeded"),
            grid: grid,
            trackerByTimbre: trackerByTimbre,
            trackerBySNRWhite: trackerBySNRWhite,
            trackerBySNRPink: trackerBySNRPink,
            trackerByVibrato: trackerByVibrato,
            trackerNote:
                "tracker* rows run the whole pipeline on 0.4 s sustained notes, skipping the first 120 ms. The other "
                + "rows are the detector alone, on isolated frames, where voicedRate is the dip threshold's decision.",
            byTimbre: byTimbre,
            bySNRWhite: bySNRWhite,
            bySNRPink: bySNRPink,
            byVibrato: byVibrato,
            byRegister: byRegister,
            byRegisterAt20dB: byRegisterAt20dB,
            at48kHz: at48kHz
        ),
        to: output.appendingPathComponent("accuracy.json")
    )
}

func runComparison(output: URL) throws {
    let base = YINConfiguration()
    let detectors: [(String, @Sendable () -> FrameDetector)] = [
        ("spectral peak", { SpectralPeakDetector(configuration: base) }),
        ("autocorrelation (YIN step 1)", { AutocorrelationDetector(configuration: base) }),
        ("difference function (step 2)", { DifferenceOnlyDetector(configuration: base) }),
        (
            "normalised, deepest dip (step 3)",
            {
                var configuration = base
                configuration.threshold = 0
                configuration.fallbackMargin = 0
                configuration.refinement = .none
                return YINFrameDetector(configuration: configuration, usesVoicingDecision: false)
            }
        ),
        (
            "plus threshold (step 4)",
            {
                var configuration = base
                configuration.fallbackMargin = 0
                configuration.refinement = .none
                return YINFrameDetector(configuration: configuration, usesVoicingDecision: false)
            }
        ),
        (
            "plus parabola on normalised curve",
            {
                var configuration = base
                configuration.fallbackMargin = 0
                configuration.refinement = .parabolicNormalized
                return YINFrameDetector(configuration: configuration, usesVoicingDecision: false)
            }
        ),
        (
            "plus parabola on difference (step 5)",
            {
                var configuration = base
                configuration.fallbackMargin = 0
                return YINFrameDetector(configuration: configuration, usesVoicingDecision: false)
            }
        ),
        (
            "plus first dip near the deepest (shipped)",
            { YINFrameDetector(configuration: base, usesVoicingDecision: false) }
        ),
    ]

    func sweep(_ condition: Condition, seed: UInt64) -> [ConditionResult] {
        detectors.map { name, factory in
            print(name)
            return measure(condition, seed: seed, makeDetector: factory).summary(label: name)
        }
    }

    try writeJSON(
        ComparisonReport(
            host: .current(note: "accuracy figures are machine independent; signals are seeded"),
            conditions: "same grid as accuracy.json; every detector sees the same seeded clips; no voicing gate",
            detectorsClean: sweep(Condition(), seed: 11),
            detectorsAt20dB: sweep(Condition(snrDB: 20), seed: 12),
            detectorsAt5dB: sweep(Condition(snrDB: 5), seed: 15),
            detectorsBrightClean: sweep(Condition(timbre: .bright), seed: 13),
            detectorsWeakFundamental: sweep(Condition(timbre: .weakFundamental), seed: 14)
        ),
        to: output.appendingPathComponent("comparison.json")
    )
}

/// False voicing on noise alone at a speaking-room level, through the whole tracker.
private func falseVoicedRate(tracker: PitchTrackerConfiguration, kind: NoiseKind) -> Double {
    let counts = parallelMap(8) { worker -> (voiced: Int, frames: Int) in
        var rng = SplitMix64(seed: 90 &+ UInt64(worker))
        var noise = Signal.noise(kind: kind, count: 44_100, rng: &rng)
        Signal.normalize(&noise, levelDB: -35)
        let pipeline = AnalysisPipeline(configuration: AnalysisConfiguration(tracker: tracker))
        var voiced = 0
        var frames = 0
        noise.withUnsafeBufferPointer { buffer in
            pipeline.process(
                buffer,
                onPitch: { frame in
                    frames += 1
                    if frame.frequency != nil { voiced += 1 }
                },
                onColumn: { _ in }
            )
        }
        return (voiced, frames)
    }
    return Double(counts.reduce(0) { $0 + $1.voiced }) / Double(counts.reduce(0) { $0 + $1.frames })
}

func runThreshold(output: URL) throws {
    let snrs: [Double] = [30, 20, 10, 5, 0]
    let rows = [0.10, 0.15, 0.20, 0.25, 0.30, 0.40, 0.50].map { threshold -> ThresholdRow in
        print("voicing threshold \(threshold)")
        let tracker = PitchTrackerConfiguration(maxAperiodicity: Float(threshold))
        var voiced: [String: Double] = [:]
        var accurate: [String: Double] = [:]
        var octave: [String: Double] = [:]
        for snr in snrs {
            let result = measureTracker(Condition(snrDB: snr), seed: 21, tracker: tracker).summary(label: "")
            voiced["\(Int(snr))"] = result.voicedRate
            accurate["\(Int(snr))"] = result.rawPitchAccuracy50
            octave["\(Int(snr))"] = result.octaveErrorRate
        }
        return ThresholdRow(
            voicingThreshold: threshold,
            voicedRateBySNR: voiced,
            rawPitchAccuracyBySNR: accurate,
            octaveErrorRateBySNR: octave,
            falseVoicedWhiteNoise: falseVoicedRate(tracker: tracker, kind: .white),
            falseVoicedPinkNoise: falseVoicedRate(tracker: tracker, kind: .pink)
        )
    }
    try writeJSON(
        ThresholdReport(
            host: .current(note: "accuracy figures are machine independent; signals are seeded"),
            note: "vowelAh under white noise, whole pipeline, with the dip threshold fixed at the shipped 0.15",
            rows: rows
        ),
        to: output.appendingPathComponent("threshold.json")
    )
}
