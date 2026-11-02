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

struct AccuracyReport: Encodable {
    let host: HostInfo
    let grid: String
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
    let detectorsBrightClean: [ConditionResult]
    let detectorsWeakFundamental: [ConditionResult]
}

struct ThresholdRow: Encodable {
    let threshold: Double
    let voicedRateBySNR: [String: Double]
    let rawPitchAccuracyBySNR: [String: Double]
    let falseVoicedWhiteNoise: Double
    let falseVoicedPinkNoise: Double
    let octaveErrorRateAt5dB: Double
}

struct ThresholdReport: Encodable {
    let host: HostInfo
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
                configuration.refinement = .none
                return YINFrameDetector(configuration: configuration, usesVoicingDecision: false)
            }
        ),
        (
            "plus threshold (step 4)",
            {
                var configuration = base
                configuration.refinement = .none
                return YINFrameDetector(configuration: configuration, usesVoicingDecision: false)
            }
        ),
        (
            "plus parabola on normalised curve",
            {
                var configuration = base
                configuration.refinement = .parabolicNormalized
                return YINFrameDetector(configuration: configuration, usesVoicingDecision: false)
            }
        ),
        (
            "plus parabola on difference (step 5, shipped)",
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
            detectorsBrightClean: sweep(Condition(timbre: .bright), seed: 13),
            detectorsWeakFundamental: sweep(Condition(timbre: .weakFundamental), seed: 14)
        ),
        to: output.appendingPathComponent("comparison.json")
    )
}

/// False voicing on pure noise, using the same frame length as the detector.
private func falseVoicedRate(threshold: Float, kind: NoiseKind) -> Double {
    let configuration = YINConfiguration(threshold: threshold)
    let frames = 4_000
    let counts = parallelMap(8) { worker -> Int in
        let detector = YINDetector(configuration: configuration)
        var rng = SplitMix64(seed: 90 &+ UInt64(worker))
        var hits = 0
        for _ in 0..<(frames / 8) {
            let noise = Signal.noise(kind: kind, count: configuration.requiredSamples, rng: &rng)
            if noise.withUnsafeBufferPointer({ detector.estimate($0) })?.isPeriodic == true {
                hits += 1
            }
        }
        return hits
    }
    return Double(counts.reduce(0, +)) / Double(frames)
}

func runThreshold(output: URL) throws {
    let snrs: [Double] = [30, 20, 10, 5, 0]
    let rows = [0.05, 0.10, 0.15, 0.20, 0.30, 0.40].map { threshold -> ThresholdRow in
        print("threshold \(threshold)")
        let value = Float(threshold)
        let factory: @Sendable () -> FrameDetector = {
            YINFrameDetector(configuration: YINConfiguration(threshold: value))
        }
        var voiced: [String: Double] = [:]
        var accurate: [String: Double] = [:]
        var octaveAt5 = 0.0
        for snr in snrs {
            let result = measure(Condition(snrDB: snr), seed: 21, makeDetector: factory).summary(label: "")
            voiced["\(Int(snr))"] = result.voicedRate
            accurate["\(Int(snr))"] = result.rawPitchAccuracy50
            if snr == 5 { octaveAt5 = result.octaveErrorRate }
        }
        return ThresholdRow(
            threshold: threshold,
            voicedRateBySNR: voiced,
            rawPitchAccuracyBySNR: accurate,
            falseVoicedWhiteNoise: falseVoicedRate(threshold: value, kind: .white),
            falseVoicedPinkNoise: falseVoicedRate(threshold: value, kind: .pink),
            octaveErrorRateAt5dB: octaveAt5
        )
    }
    try writeJSON(
        ThresholdReport(
            host: .current(note: "accuracy figures are machine independent; signals are seeded"),
            rows: rows
        ),
        to: output.appendingPathComponent("threshold.json")
    )
}
