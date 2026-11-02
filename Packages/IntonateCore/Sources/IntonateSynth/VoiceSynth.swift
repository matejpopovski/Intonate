import Foundation

/// A small seeded generator. Tests and benchmarks must produce the same signal on every machine, and
/// the system generator is deliberately not reproducible.
public struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    public mutating func unit() -> Double {
        Double.random(in: 0..<1, using: &self)
    }

    /// Standard normal sample, by Box-Muller.
    public mutating func gaussian() -> Double {
        let radius = sqrt(-2 * log(1 - unit()))
        return radius * cos(2 * .pi * unit())
    }
}

/// Source spectra for the test signals. Each is a case a pitch detector can get wrong in a different way.
public enum Timbre: String, CaseIterable, Sendable, Codable {
    /// A pure tone: no harmonics to lean on, and a best case for the interpolation.
    case sine
    /// Sawtooth-like series with slow rolloff. Every harmonic is strong, which invites octave errors.
    case bright
    /// Glottal-like source through the formants of a male /a/ (730, 1090, 2440 Hz).
    case vowelAh
    /// Same source through /i/ (270, 2290, 3010 Hz), where the first formant sits right on low
    /// sung fundamentals and second harmonics.
    case vowelEe
    /// The fundamental attenuated 20 dB under the second harmonic, the hardest case for a method
    /// that picks a spectral peak.
    case weakFundamental

    private struct Formant {
        let frequency: Double
        let bandwidth: Double
    }

    private var formants: [Formant] {
        switch self {
        case .vowelAh:
            return [
                Formant(frequency: 730, bandwidth: 90), Formant(frequency: 1_090, bandwidth: 110),
                Formant(frequency: 2_440, bandwidth: 170),
            ]
        case .vowelEe:
            return [
                Formant(frequency: 270, bandwidth: 70), Formant(frequency: 2_290, bandwidth: 120),
                Formant(frequency: 3_010, bandwidth: 170),
            ]
        default:
            return []
        }
    }

    /// Linear amplitude of harmonic `k` of `fundamental`.
    public func harmonicAmplitude(_ k: Int, fundamental: Double) -> Double {
        let harmonic = Double(k)
        switch self {
        case .sine:
            return k == 1 ? 1 : 0
        case .bright:
            return 1 / harmonic
        case .weakFundamental:
            return k == 1 ? 0.05 : 1 / (harmonic - 1)
        case .vowelAh, .vowelEe:
            // A -12 dB/octave glottal source, then the magnitude of each second-order resonance.
            var gain = 1 / (harmonic * harmonic)
            let frequency = harmonic * fundamental
            for formant in formants {
                let f0 = formant.frequency
                let numerator = f0 * f0
                let squaredPart = pow(f0 * f0 - frequency * frequency, 2)
                let dampingPart = pow(formant.bandwidth * frequency, 2)
                gain *= numerator / sqrt(squaredPart + dampingPart)
            }
            return gain
        }
    }
}

/// An f0 trajectory. Kept as a closure so that a scripted singer and a benchmark vibrato are the same type.
public struct F0Contour: Sendable {
    public let frequency: @Sendable (Double) -> Double

    public init(frequency: @escaping @Sendable (Double) -> Double) {
        self.frequency = frequency
    }

    public static func constant(_ hz: Double) -> F0Contour {
        F0Contour { _ in hz }
    }

    /// Sinusoidal vibrato. Sung classical vibrato is about 5 to 7 Hz at 50 to 100 cents of depth.
    public static func vibrato(center: Double, rate: Double, depthCents: Double, phase: Double = 0) -> F0Contour {
        F0Contour { time in
            center * pow(2, depthCents * sin(2 * .pi * rate * time + phase) / 1200)
        }
    }

    public static func step(from first: Double, to second: Double, at instant: Double) -> F0Contour {
        F0Contour { time in time < instant ? first : second }
    }
}

/// Additive voice synthesis, band-limited below Nyquist. Every harmonic shares one integrated phase,
/// so a moving contour stays exactly harmonic: the ground truth stays well defined under vibrato,
/// which a filtered pulse train would not guarantee.
public struct VoiceSynth: Sendable {
    public let sampleRate: Double
    public let timbre: Timbre

    private static let maxHarmonics = 48
    /// Harmonic gains change slowly with f0, so recomputing them every sample would be wasted work.
    private static let gainBlock = 32

    private var harmonicPhases: [Double]
    private var gains = [Double](repeating: 0, count: VoiceSynth.maxHarmonics)
    private var harmonicCount = 0
    private var normalization = 0.0
    private var phase: Double
    private var sampleIndex: Int64 = 0

    public init(sampleRate: Double, timbre: Timbre, seed: UInt64 = 1) {
        self.sampleRate = sampleRate
        self.timbre = timbre
        var rng = SplitMix64(seed: seed)
        harmonicPhases = (0..<Self.maxHarmonics).map { _ in rng.unit() }
        phase = rng.unit()
    }

    /// Renders `count` samples at unit RMS for a steady tone, continuing from the previous call.
    /// `frequency` receives the stream time and returns the f0, and `amplitude` the linear gain.
    /// While the amplitude is zero the f0 is not read, so a contour need not define one in rests.
    public mutating func render(
        into output: UnsafeMutablePointer<Float>,
        count: Int,
        frequency: (Double) -> Double,
        amplitude: (Double) -> Double = { _ in 1 }
    ) {
        let maxHarmonics = Self.maxHarmonics
        for index in 0..<count {
            let time = Double(sampleIndex) / sampleRate
            let gain = amplitude(time)
            if gain <= 0 {
                output[index] = 0
                sampleIndex += 1
                continue
            }
            let f0 = frequency(time)
            if sampleIndex % Int64(Self.gainBlock) == 0 || harmonicCount == 0 {
                harmonicCount = min(maxHarmonics, Int(0.45 * sampleRate / f0))
                var power = 0.0
                for k in 0..<harmonicCount {
                    let value = timbre.harmonicAmplitude(k + 1, fundamental: f0)
                    gains[k] = value
                    power += value * value / 2
                }
                normalization = 1 / max(sqrt(power), 1e-9)
            }
            var sample = 0.0
            for k in 0..<harmonicCount {
                sample += gains[k] * sin(2 * .pi * (Double(k + 1) * phase + harmonicPhases[k]))
            }
            output[index] = Float(sample * normalization * gain)
            phase += f0 / sampleRate
            if phase >= 1 { phase -= 1 }
            sampleIndex += 1
        }
    }

    /// A whole clip at an exact RMS level.
    public static func clip(
        contour: F0Contour,
        duration: Double,
        sampleRate: Double,
        timbre: Timbre,
        seed: UInt64 = 1,
        levelDB: Double = -18
    ) -> [Float] {
        var synth = VoiceSynth(sampleRate: sampleRate, timbre: timbre, seed: seed)
        let count = Int(duration * sampleRate)
        var output = [Float](repeating: 0, count: count)
        output.withUnsafeMutableBufferPointer { buffer in
            synth.render(into: buffer.baseAddress!, count: count, frequency: contour.frequency)
        }
        Signal.normalize(&output, levelDB: levelDB)
        return output
    }
}

public enum NoiseKind: String, CaseIterable, Sendable, Codable {
    case white
    /// -3 dB/octave, closer to room and handling noise than white noise is.
    case pink
}

public enum Signal {
    public static func rms(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        return sqrt(sum / Double(samples.count))
    }

    public static func normalize(_ samples: inout [Float], levelDB: Double) {
        let current = rms(samples)
        guard current > 0 else { return }
        let gain = Float(pow(10, levelDB / 20) / current)
        for index in samples.indices {
            samples[index] *= gain
        }
    }

    public static func noise(kind: NoiseKind, count: Int, rng: inout SplitMix64) -> [Float] {
        var output = [Float](repeating: 0, count: count)
        switch kind {
        case .white:
            for index in 0..<count {
                output[index] = Float(rng.gaussian())
            }
        case .pink:
            // Kellet's refined filter: a -3 dB/octave fit to within 0.05 dB across the audio band.
            var b0 = 0.0
            var b1 = 0.0
            var b2 = 0.0
            var b3 = 0.0
            var b4 = 0.0
            var b5 = 0.0
            var b6 = 0.0
            for index in 0..<count {
                let white = rng.gaussian()
                b0 = 0.99886 * b0 + white * 0.0555179
                b1 = 0.99332 * b1 + white * 0.0750759
                b2 = 0.96900 * b2 + white * 0.1538520
                b3 = 0.86650 * b3 + white * 0.3104856
                b4 = 0.55000 * b4 + white * 0.5329522
                b5 = -0.7616 * b5 - white * 0.0168980
                output[index] = Float(b0 + b1 + b2 + b3 + b4 + b5 + b6 + white * 0.5362)
                b6 = white * 0.115926
            }
        }
        return output
    }

    /// Mixes noise into `clean` so that the measured SNR over the clip is exactly `snrDB`.
    public static func mix(_ clean: [Float], snrDB: Double, kind: NoiseKind, rng: inout SplitMix64) -> [Float] {
        let noiseSamples = noise(kind: kind, count: clean.count, rng: &rng)
        let gain = Float(rms(clean) / pow(10, snrDB / 20) / rms(noiseSamples))
        var output = clean
        for index in output.indices {
            output[index] += noiseSamples[index] * gain
        }
        return output
    }
}
