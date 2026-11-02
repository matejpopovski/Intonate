import Accelerate
import Foundation
import IntonateDSP

/// What a benchmark needs from a pitch detector, for one frame of audio.
protocol FrameDetector {
    var requiredSamples: Int { get }
    /// Returns the frequency, and whether the detector itself considers the frame voiced.
    func detect(_ frame: UnsafeBufferPointer<Float>) -> (frequency: Double, isVoiced: Bool)?
    /// The offset into the frame that the estimate describes, for checking against a moving contour.
    func centerOffset(forFrequency frequency: Double) -> Double
}

struct YINFrameDetector: FrameDetector {
    let detector: YINDetector
    /// With gating off, the best dip counts even if it never crossed the threshold.
    var usesVoicingDecision = true

    init(configuration: YINConfiguration, usesVoicingDecision: Bool = true) {
        detector = YINDetector(configuration: configuration)
        self.usesVoicingDecision = usesVoicingDecision
    }

    var requiredSamples: Int { detector.configuration.requiredSamples }

    func detect(_ frame: UnsafeBufferPointer<Float>) -> (frequency: Double, isVoiced: Bool)? {
        guard let estimate = detector.estimate(frame) else { return nil }
        return (estimate.frequency, usesVoicingDecision ? estimate.isPeriodic : true)
    }

    func centerOffset(forFrequency frequency: Double) -> Double {
        let configuration = detector.configuration
        return (Double(configuration.windowLength) + configuration.sampleRate / frequency) / 2
    }
}

/// YIN's starting point, kept for comparison: the largest autocorrelation peak in the lag range.
/// Peaks at T, 2T, 3T are nearly equal, so this one wanders onto subharmonics.
final class AutocorrelationDetector: FrameDetector {
    private let configuration: YINConfiguration

    init(configuration: YINConfiguration) {
        self.configuration = configuration
    }

    var requiredSamples: Int { configuration.requiredSamples }

    func detect(_ frame: UnsafeBufferPointer<Float>) -> (frequency: Double, isVoiced: Bool)? {
        guard let x = frame.baseAddress else { return nil }
        let window = vDSP_Length(configuration.windowLength)
        var values = [Float](repeating: 0, count: configuration.maxLag + 2)
        for lag in (configuration.minLag - 1)...(configuration.maxLag + 1) {
            vDSP_dotpr(x, 1, x + lag, 1, &values[lag], window)
        }
        var best = configuration.minLag
        for lag in configuration.minLag...configuration.maxLag where values[lag] > values[best] {
            best = lag
        }
        guard values[best] > 0 else { return nil }
        let left = Double(values[best - 1])
        let middle = Double(values[best])
        let right = Double(values[best + 1])
        let curvature = left - 2 * middle + right
        let offset = curvature < 0 ? max(-1, min(1, 0.5 * (left - right) / curvature)) : 0
        return (configuration.sampleRate / (Double(best) + offset), true)
    }

    func centerOffset(forFrequency frequency: Double) -> Double {
        (Double(configuration.windowLength) + configuration.sampleRate / frequency) / 2
    }
}

/// The obvious spectral method: take the strongest bin. It reports the loudest partial, which on a
/// sung vowel is usually a harmonic near a formant and not the fundamental.
final class SpectralPeakDetector: FrameDetector {
    private let analyzer: SpectrumAnalyzer
    private let configuration: YINConfiguration
    private let fftSize: Int

    init(configuration: YINConfiguration, fftSize: Int = 4_096) {
        self.configuration = configuration
        self.fftSize = fftSize
        analyzer = SpectrumAnalyzer(fftSize: fftSize, sampleRate: configuration.sampleRate, bandMap: .waterfall)
    }

    var requiredSamples: Int { fftSize }

    func detect(_ frame: UnsafeBufferPointer<Float>) -> (frequency: Double, isVoiced: Bool)? {
        guard let x = frame.baseAddress else { return nil }
        var power = [Float](repeating: 0, count: fftSize / 2 + 1)
        analyzer.powerSpectrum(x, into: &power)
        let binWidth = configuration.sampleRate / Double(fftSize)
        let first = max(1, Int(configuration.minFrequency / binWidth))
        let last = min(fftSize / 2 - 1, Int(configuration.maxFrequency / binWidth) + 1)
        var best = first
        for bin in first...last where power[bin] > power[best] {
            best = bin
        }
        guard power[best] > 0 else { return nil }
        let left = log(Double(max(power[best - 1], 1e-20)))
        let middle = log(Double(power[best]))
        let right = log(Double(max(power[best + 1], 1e-20)))
        let curvature = left - 2 * middle + right
        let offset = curvature < 0 ? max(-1, min(1, 0.5 * (left - right) / curvature)) : 0
        return ((Double(best) + offset) * binWidth, true)
    }

    func centerOffset(forFrequency frequency: Double) -> Double {
        Double(fftSize) / 2
    }
}

/// YIN stopped after step 2: the deepest difference-function dip anywhere in the lag range.
final class DifferenceOnlyDetector: FrameDetector {
    private let detector: YINDetector
    private let configuration: YINConfiguration

    init(configuration: YINConfiguration) {
        self.configuration = configuration
        detector = YINDetector(configuration: configuration)
    }

    var requiredSamples: Int { configuration.requiredSamples }

    func detect(_ frame: UnsafeBufferPointer<Float>) -> (frequency: Double, isVoiced: Bool)? {
        let values = detector.differenceFunction(frame)
        var best = configuration.minLag
        for lag in configuration.minLag...configuration.maxLag where values[lag] < values[best] {
            best = lag
        }
        return (configuration.sampleRate / Double(best), true)
    }

    func centerOffset(forFrequency frequency: Double) -> Double {
        (Double(configuration.windowLength) + configuration.sampleRate / frequency) / 2
    }
}
