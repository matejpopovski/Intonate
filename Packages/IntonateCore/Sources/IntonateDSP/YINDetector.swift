import Accelerate
import Foundation

/// Tunable parts of the YIN estimator (de Cheveigné and Kawahara, JASA 2002).
public struct YINConfiguration: Sendable, Equatable {
    /// How the squared-difference function of step 2 is computed. Both give the same values to
    /// within rounding; the choice is about speed and is measured in `results/compute_host.json`.
    public enum DifferenceMethod: String, Sendable, CaseIterable {
        /// One dot product per lag, O(W·τ).
        case direct
        /// Cross-correlation through a real FFT, O(N log N).
        case fft
    }

    /// Which curve step 5 fits its parabola to.
    public enum Refinement: String, Sendable, CaseIterable {
        /// Keep the integer lag. A one-sample error at C6 is about 40 cents.
        case none
        /// Fit the raw difference function, which has no normalisation bias.
        case parabolicDifference
        /// Fit the normalised curve, which leans towards longer lags on low notes.
        case parabolicNormalized
    }

    public var sampleRate: Double
    /// Integration window W, in samples.
    public var windowLength: Int
    public var minFrequency: Double
    public var maxFrequency: Double
    /// Dip depth on the normalised curve that counts as periodic (step 4).
    public var threshold: Float
    /// When no dip crosses the threshold, take the first dip within this margin of the deepest one.
    /// Plain YIN takes the deepest, which on a noisy frame is as often 2T or 3T as it is T.
    public var fallbackMargin: Float
    public var difference: DifferenceMethod
    public var refinement: Refinement

    public init(
        sampleRate: Double = 44_100,
        windowLength: Int? = nil,
        minFrequency: Double = 60,
        maxFrequency: Double = 1_400,
        threshold: Float = 0.15,
        fallbackMargin: Float = 0.1,
        difference: DifferenceMethod = .fft,
        refinement: Refinement = .parabolicDifference
    ) {
        self.sampleRate = sampleRate
        // 1024 samples at 44.1 kHz. The integration has to span a period of the lowest note, 1.4 of
        // them here, and every extra sample is latency. Scaling keeps the duration the same at 48 kHz.
        self.windowLength = windowLength ?? Int((1_024 / 44_100 * sampleRate).rounded())
        self.minFrequency = minFrequency
        self.maxFrequency = maxFrequency
        self.threshold = threshold
        self.fallbackMargin = fallbackMargin
        self.difference = difference
        self.refinement = refinement
    }

    public var minLag: Int { max(2, Int(floor(sampleRate / maxFrequency))) }
    public var maxLag: Int { Int(ceil(sampleRate / minFrequency)) }
    /// Samples one call to `estimate` consumes.
    public var requiredSamples: Int { windowLength + maxLag + 1 }
}

public struct PitchEstimate: Sendable, Equatable {
    public var frequency: Double
    /// Period in samples, with the sub-sample refinement applied.
    public var lag: Double
    /// Height of the chosen dip on the normalised curve: 0 is perfectly periodic, near 1 is noise.
    public var aperiodicity: Float
    /// False when no dip crossed the threshold and this is only the global minimum.
    public var isPeriodic: Bool
}

/// Hand-written YIN. All buffers are allocated once, so `estimate` is safe to call at audio rate.
public final class YINDetector {
    public let configuration: YINConfiguration

    private let window: Int
    private let maxLag: Int
    /// d(τ) for τ in 0...maxLag + 1. Index maxLag + 1 exists so that a minimum at maxLag has a right neighbour.
    private var difference: [Float]
    private var normalized: [Float]
    private let correlator: FFTCorrelator?

    public init(configuration: YINConfiguration = YINConfiguration()) {
        precondition(configuration.windowLength > 0)
        precondition(configuration.minLag < configuration.maxLag)
        self.configuration = configuration
        window = configuration.windowLength
        maxLag = configuration.maxLag
        difference = [Float](repeating: 0, count: maxLag + 2)
        normalized = [Float](repeating: 1, count: maxLag + 2)
        correlator =
            configuration.difference == .fft
            ? FFTCorrelator(window: window, signalLength: window + maxLag + 1)
            : nil
    }

    /// Returns the best estimate for the first `requiredSamples` of `samples`, or nil for digital
    /// silence, where the difference function is zero everywhere and no lag means anything.
    public func estimate(_ samples: UnsafeBufferPointer<Float>) -> PitchEstimate? {
        precondition(samples.count >= configuration.requiredSamples, "not enough samples for this window")
        guard let base = samples.baseAddress else { return nil }

        computeDifference(base)
        guard normalizeDifference() else { return nil }

        let (lag, isPeriodic) = selectLag()
        let refined = refine(lag: lag)
        return PitchEstimate(
            frequency: configuration.sampleRate / refined,
            lag: refined,
            aperiodicity: normalized[lag],
            isPeriodic: isPeriodic
        )
    }

    /// Exposes step 2 so the two implementations can be compared directly in tests.
    public func differenceFunction(_ samples: UnsafeBufferPointer<Float>) -> [Float] {
        computeDifference(samples.baseAddress!)
        return difference
    }

    /// Step 2. d(τ) = Σ (x[j] - x[j+τ])² = e(0) + e(τ) - 2r(τ), where e is the energy of a W-sample
    /// frame starting at τ and r is the cross-correlation of the two frames.
    private func computeDifference(_ x: UnsafePointer<Float>) {
        var energy: Double = 0
        for j in 0..<window {
            energy += Double(x[j]) * Double(x[j])
        }
        let zeroLagEnergy = energy

        difference.withUnsafeMutableBufferPointer { output in
            output[0] = 0
            if let correlator {
                correlator.correlate(x) { correlation in
                    var slidingEnergy = zeroLagEnergy
                    for lag in 1...(maxLag + 1) {
                        let leaving = Double(x[lag - 1])
                        let entering = Double(x[window + lag - 1])
                        slidingEnergy += entering * entering - leaving * leaving
                        output[lag] = Float(max(0, zeroLagEnergy + slidingEnergy - 2 * Double(correlation[lag])))
                    }
                }
            } else {
                var slidingEnergy = zeroLagEnergy
                for lag in 1...(maxLag + 1) {
                    let leaving = Double(x[lag - 1])
                    let entering = Double(x[window + lag - 1])
                    slidingEnergy += entering * entering - leaving * leaving
                    var correlation: Float = 0
                    vDSP_dotpr(x, 1, x + lag, 1, &correlation, vDSP_Length(window))
                    output[lag] = Float(max(0, zeroLagEnergy + slidingEnergy - 2 * Double(correlation)))
                }
            }
        }
    }

    /// Step 3, the cumulative mean normalised difference. Returns false if the signal is silent.
    private func normalizeDifference() -> Bool {
        var runningSum: Double = 0
        normalized[0] = 1
        for lag in 1...(maxLag + 1) {
            runningSum += Double(difference[lag])
            guard runningSum > 0 else {
                normalized[lag] = 1
                continue
            }
            normalized[lag] = Float(Double(difference[lag]) * Double(lag) / runningSum)
        }
        return runningSum > 0
    }

    /// Step 4. Taking the first dip under the threshold, not the deepest, is what keeps YIN off the
    /// subharmonics: dips at 2T and 3T are about as deep as the dip at T.
    private func selectLag() -> (lag: Int, isPeriodic: Bool) {
        if let lag = firstDip(below: configuration.threshold) {
            return (lag, true)
        }
        let first = configuration.minLag
        var deepest = first
        for candidate in first...maxLag where normalized[candidate] < normalized[deepest] {
            deepest = candidate
        }
        return (firstDip(below: normalized[deepest] + configuration.fallbackMargin) ?? deepest, false)
    }

    private func firstDip(below limit: Float) -> Int? {
        var lag = configuration.minLag
        while lag <= maxLag {
            if normalized[lag] < limit {
                while lag < maxLag, normalized[lag + 1] < normalized[lag] {
                    lag += 1
                }
                return lag
            }
            lag += 1
        }
        return nil
    }

    /// Step 5. Fits a parabola through the dip and its neighbours.
    private func refine(lag: Int) -> Double {
        let curve: [Float]
        switch configuration.refinement {
        case .none:
            return Double(lag)
        case .parabolicDifference:
            curve = difference
        case .parabolicNormalized:
            curve = normalized
        }
        guard lag > 0, lag <= maxLag else { return Double(lag) }
        let left = Double(curve[lag - 1])
        let middle = Double(curve[lag])
        let right = Double(curve[lag + 1])
        let curvature = left - 2 * middle + right
        guard curvature > 0 else { return Double(lag) }
        let offset = 0.5 * (left - right) / curvature
        return Double(lag) + max(-1, min(1, offset))
    }
}

/// Real-FFT cross-correlation of the first `window` samples with the first `signalLength` samples.
final class FFTCorrelator {
    private let window: Int
    private let signalLength: Int
    private let fftSize: Int
    private let log2Size: vDSP_Length
    private let setup: FFTSetupD
    private var frameReal: [Double]
    private var frameImag: [Double]
    private var signalReal: [Double]
    private var signalImag: [Double]
    private var scratch: [Double]
    private var correlation: [Double]

    init(window: Int, signalLength: Int) {
        self.window = window
        self.signalLength = signalLength
        // Long enough that the circular correlation does not wrap into the lags we read.
        var size = 2
        while size < window + signalLength { size <<= 1 }
        fftSize = size
        log2Size = vDSP_Length(size.trailingZeroBitCount)
        guard let created = vDSP_create_fftsetupD(log2Size, FFTRadix(kFFTRadix2)) else {
            fatalError("vDSP could not allocate an FFT of size \(size)")
        }
        setup = created
        let half = size / 2
        frameReal = [Double](repeating: 0, count: half)
        frameImag = frameReal
        signalReal = frameReal
        signalImag = frameReal
        scratch = [Double](repeating: 0, count: size)
        correlation = scratch
    }

    deinit {
        vDSP_destroy_fftsetupD(setup)
    }

    /// Double precision because the dip for a clean tone is tiny next to the frame energy, and Float
    /// rounding in the transform would land on the same scale as the dip itself.
    func correlate(_ x: UnsafePointer<Float>, body: (UnsafeBufferPointer<Double>) -> Void) {
        let half = vDSP_Length(fftSize / 2)
        scratch.withUnsafeMutableBufferPointer { work in
            let time = work.baseAddress!

            frameReal.withUnsafeMutableBufferPointer { realPointer in
                frameImag.withUnsafeMutableBufferPointer { imagPointer in
                    var frame = DSPDoubleSplitComplex(realp: realPointer.baseAddress!, imagp: imagPointer.baseAddress!)
                    vDSP_vspdp(x, 1, time, 1, vDSP_Length(window))
                    vDSP_vclrD(time + window, 1, vDSP_Length(fftSize - window))
                    time.withMemoryRebound(to: DSPDoubleComplex.self, capacity: fftSize / 2) {
                        vDSP_ctozD($0, 2, &frame, 1, half)
                    }
                    vDSP_fft_zripD(setup, &frame, 1, log2Size, FFTDirection(kFFTDirection_Forward))

                    signalReal.withUnsafeMutableBufferPointer { signalRealPointer in
                        signalImag.withUnsafeMutableBufferPointer { signalImagPointer in
                            var signal = DSPDoubleSplitComplex(
                                realp: signalRealPointer.baseAddress!,
                                imagp: signalImagPointer.baseAddress!
                            )
                            vDSP_vspdp(x, 1, time, 1, vDSP_Length(signalLength))
                            vDSP_vclrD(time + signalLength, 1, vDSP_Length(fftSize - signalLength))
                            time.withMemoryRebound(to: DSPDoubleComplex.self, capacity: fftSize / 2) {
                                vDSP_ctozD($0, 2, &signal, 1, half)
                            }
                            vDSP_fft_zripD(setup, &signal, 1, log2Size, FFTDirection(kFFTDirection_Forward))

                            // Packed format: DC and Nyquist are both real and share slot 0.
                            let dc = frame.realp[0] * signal.realp[0]
                            let nyquist = frame.imagp[0] * signal.imagp[0]
                            // conj(F) · S
                            for k in 1..<Int(half) {
                                let re = frame.realp[k] * signal.realp[k] + frame.imagp[k] * signal.imagp[k]
                                let im = frame.realp[k] * signal.imagp[k] - frame.imagp[k] * signal.realp[k]
                                signal.realp[k] = re
                                signal.imagp[k] = im
                            }
                            signal.realp[0] = dc
                            signal.imagp[0] = nyquist

                            vDSP_fft_zripD(setup, &signal, 1, log2Size, FFTDirection(kFFTDirection_Inverse))
                            correlation.withUnsafeMutableBufferPointer { output in
                                output.baseAddress!.withMemoryRebound(
                                    to: DSPDoubleComplex.self,
                                    capacity: fftSize / 2
                                ) {
                                    vDSP_ztocD(&signal, 1, $0, 2, half)
                                }
                                // Each forward zrip scales by 2 and the inverse by N.
                                var scale = 1 / Double(4 * fftSize)
                                vDSP_vsmulD(
                                    output.baseAddress!,
                                    1,
                                    &scale,
                                    output.baseAddress!,
                                    1,
                                    vDSP_Length(fftSize)
                                )
                            }
                        }
                    }
                }
            }
        }
        correlation.withUnsafeBufferPointer(body)
    }
}
