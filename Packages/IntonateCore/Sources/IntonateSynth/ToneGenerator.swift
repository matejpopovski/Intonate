import Foundation
import IntonateDSP

/// The reference pitch a singer hears before an exercise. It runs inside an audio render callback,
/// so the controlling thread communicates only through atomics, and the gain ramps to avoid clicks.
public final class ToneGenerator: @unchecked Sendable {
    private let targetFrequency = AtomicWord()
    private let sampleRate: Double

    private var phase = 0.0
    private var gain = 0.0
    private var frequency = 0.0
    private let gainStep: Double

    /// A soft organ-like tone: the upper partials make low notes audible on a phone speaker.
    private static let partials: [(harmonic: Double, amplitude: Double)] = [(1, 0.7), (2, 0.2), (3, 0.1)]
    private static let level = 0.25

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        gainStep = 1 / (0.015 * sampleRate)
    }

    /// Sets the pitch to play, or nil to fade out. Safe from any thread.
    public func setFrequency(_ hz: Double?) {
        targetFrequency.store((hz ?? 0).bitPattern)
    }

    /// Render callback body. No locks and no allocation.
    public func render(into output: UnsafeMutablePointer<Float>, count: Int) {
        let target = Double(bitPattern: targetFrequency.load())
        for index in 0..<count {
            if target > 0 {
                frequency = target
                gain = min(1, gain + gainStep)
            } else {
                gain = max(0, gain - gainStep)
            }
            var sample = 0.0
            if gain > 0, frequency > 0 {
                for partial in Self.partials {
                    sample += partial.amplitude * sin(2 * .pi * partial.harmonic * phase)
                }
                phase += frequency / sampleRate
                if phase >= 1 { phase -= 1 }
            }
            output[index] = Float(sample * gain * Self.level)
        }
    }
}
