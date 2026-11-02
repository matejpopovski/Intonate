import IntonateSynth
import XCTest

@testable import IntonateDSP

final class YINDetectorTests: XCTestCase {
    private let sampleRate = 44_100.0

    private func detector(
        sampleRate: Double = 44_100,
        difference: YINConfiguration.DifferenceMethod = .fft,
        refinement: YINConfiguration.Refinement = .parabolicDifference
    ) -> YINDetector {
        YINDetector(
            configuration: YINConfiguration(sampleRate: sampleRate, difference: difference, refinement: refinement)
        )
    }

    private func estimate(_ detector: YINDetector, _ signal: [Float]) -> PitchEstimate? {
        signal.withUnsafeBufferPointer { detector.estimate($0) }
    }

    /// A pitch that is off the semitone grid, so results cannot depend on a lucky integer period.
    private func detuned(midi: Int) -> Double {
        Tuning.standard.frequency(midi: Double(midi) + 0.37)
    }

    func testSineIsAccurateAcrossTheVocalRange() throws {
        let yin = detector()
        let length = yin.configuration.requiredSamples
        for midi in stride(from: 36, through: 84, by: 4) {
            let truth = detuned(midi: midi)
            let signal = VoiceSynth.clip(
                contour: .constant(truth),
                duration: Double(length + 8) / sampleRate,
                sampleRate: sampleRate,
                timbre: .sine,
                seed: UInt64(midi)
            )
            let result = try XCTUnwrap(estimate(yin, signal), "midi \(midi)")
            XCTAssertTrue(result.isPeriodic, "midi \(midi)")
            XCTAssertEqual(cents(result.frequency, relativeTo: truth), 0, accuracy: 2, "midi \(midi)")
        }
    }

    func testHarmonicTimbresStayInsideFiveCentsWithNoOctaveErrors() throws {
        let yin = detector()
        let length = yin.configuration.requiredSamples
        for timbre in [Timbre.bright, .vowelAh, .vowelEe] {
            for midi in stride(from: 36, through: 84, by: 6) {
                let truth = detuned(midi: midi)
                let signal = VoiceSynth.clip(
                    contour: .constant(truth),
                    duration: Double(length + 8) / sampleRate,
                    sampleRate: sampleRate,
                    timbre: timbre,
                    seed: UInt64(midi)
                )
                let result = try XCTUnwrap(estimate(yin, signal))
                XCTAssertEqual(cents(result.frequency, relativeTo: truth), 0, accuracy: 5, "\(timbre) midi \(midi)")
            }
        }
    }

    /// The fundamental is 20 dB under the second harmonic, yet the period is still T. Peak-picking in
    /// the spectrum reads this an octave high, and resistance to that is the reason to use YIN.
    func testFindsThePeriodWhenTheFundamentalIsNearlyMissing() throws {
        let yin = detector()
        let truth = 196.0
        let signal = VoiceSynth.clip(
            contour: .constant(truth),
            duration: 0.06,
            sampleRate: sampleRate,
            timbre: .weakFundamental
        )
        let result = try XCTUnwrap(estimate(yin, signal))
        XCTAssertEqual(cents(result.frequency, relativeTo: truth), 0, accuracy: 5)
    }

    func testAgreesAt48Kilohertz() throws {
        let rate = 48_000.0
        let yin = detector(sampleRate: rate)
        let truth = 329.63
        let signal = VoiceSynth.clip(contour: .constant(truth), duration: 0.06, sampleRate: rate, timbre: .vowelAh)
        let result = try XCTUnwrap(estimate(yin, signal))
        XCTAssertEqual(cents(result.frequency, relativeTo: truth), 0, accuracy: 3)
    }

    func testEstimateDoesNotDependOnLevel() throws {
        let yin = detector()
        var signal = VoiceSynth.clip(contour: .constant(220), duration: 0.06, sampleRate: sampleRate, timbre: .vowelAh)
        let loud = try XCTUnwrap(estimate(yin, signal))
        for index in signal.indices {
            signal[index] *= 0.001
        }
        let quiet = try XCTUnwrap(estimate(yin, signal))
        XCTAssertEqual(cents(quiet.frequency, relativeTo: loud.frequency), 0, accuracy: 0.05)
    }

    func testWhiteNoiseIsNotPeriodic() {
        let yin = detector()
        var rng = SplitMix64(seed: 7)
        var periodicFrames = 0
        for _ in 0..<50 {
            let noise = Signal.noise(kind: .white, count: yin.configuration.requiredSamples, rng: &rng)
            if let result = estimate(yin, noise), result.isPeriodic {
                periodicFrames += 1
            }
        }
        XCTAssertEqual(periodicFrames, 0)
    }

    func testDigitalSilenceHasNoEstimate() {
        let yin = detector()
        XCTAssertNil(estimate(yin, [Float](repeating: 0, count: yin.configuration.requiredSamples)))
    }

    func testTwentyDecibelSNRStaysUsable() throws {
        let yin = detector()
        var rng = SplitMix64(seed: 11)
        var worst = 0.0
        for midi in stride(from: 40, through: 80, by: 5) {
            let truth = detuned(midi: midi)
            let clean = VoiceSynth.clip(
                contour: .constant(truth),
                duration: 0.06,
                sampleRate: sampleRate,
                timbre: .vowelAh,
                seed: UInt64(midi)
            )
            let noisy = Signal.mix(clean, snrDB: 20, kind: .white, rng: &rng)
            let result = try XCTUnwrap(estimate(yin, noisy))
            worst = max(worst, abs(cents(result.frequency, relativeTo: truth)))
        }
        XCTAssertLessThan(worst, 20)
    }

    func testDirectAndFFTDifferenceFunctionsAgree() {
        let direct = detector(difference: .direct)
        let fast = detector(difference: .fft)
        let signal = VoiceSynth.clip(contour: .constant(233), duration: 0.06, sampleRate: sampleRate, timbre: .bright)
        let (a, b) = signal.withUnsafeBufferPointer { (direct.differenceFunction($0), fast.differenceFunction($0)) }
        XCTAssertEqual(a.count, b.count)
        let scale = a.max() ?? 1
        for lag in a.indices {
            XCTAssertEqual(a[lag], b[lag], accuracy: scale * 2e-5, "lag \(lag)")
        }
    }

    /// One integer sample at C6 is about 40 cents, so without step 5 the top of the range is useless.
    func testParabolicRefinementReducesHighNoteError() throws {
        let coarse = detector(refinement: .none)
        let fine = detector(refinement: .parabolicDifference)
        var coarseError = 0.0
        var fineError = 0.0
        for midi in 76...84 {
            let truth = detuned(midi: midi)
            let signal = VoiceSynth.clip(
                contour: .constant(truth),
                duration: 0.06,
                sampleRate: sampleRate,
                timbre: .sine
            )
            coarseError += abs(cents(try XCTUnwrap(estimate(coarse, signal)).frequency, relativeTo: truth))
            fineError += abs(cents(try XCTUnwrap(estimate(fine, signal)).frequency, relativeTo: truth))
        }
        XCTAssertLessThan(fineError * 5, coarseError)
    }

    func testVibratoIsFollowedFrameByFrame() throws {
        let contour = F0Contour.vibrato(center: 293.66, rate: 5.5, depthCents: 60)
        let signal = VoiceSynth.clip(contour: contour, duration: 0.5, sampleRate: sampleRate, timbre: .vowelAh)
        let yin = detector()
        let required = yin.configuration.requiredSamples
        var offset = 0
        var worst = 0.0
        while offset + required <= signal.count {
            let frame = signal[offset..<(offset + required)]
            let result = try XCTUnwrap(frame.withUnsafeBufferPointer { yin.estimate($0) })
            let center = (Double(offset) + (Double(yin.configuration.windowLength) + result.lag) / 2) / sampleRate
            worst = max(worst, abs(cents(result.frequency, relativeTo: contour.frequency(center))))
            offset += 441
        }
        XCTAssertLessThan(worst, 8)
    }
}

extension YINDetectorTests {
    /// With no dip under the threshold, plain YIN takes the deepest one, which at this SNR is usually
    /// a subharmonic. Taking the first dip near the deepest should land on the true period.
    func testFallbackPrefersTheFundamentalOverASubharmonicInHeavyNoise() {
        func octaveErrors(margin: Float) -> Int {
            let yin = YINDetector(configuration: YINConfiguration(fallbackMargin: margin))
            var rng = SplitMix64(seed: 17)
            var errors = 0
            for midi in stride(from: 40, through: 76, by: 2) {
                let truth = Tuning.standard.frequency(midi: Double(midi))
                let clean = VoiceSynth.clip(
                    contour: .constant(truth),
                    duration: 0.06,
                    sampleRate: 44_100,
                    timbre: .vowelAh,
                    seed: UInt64(midi)
                )
                let noisy = Signal.mix(clean, snrDB: 5, kind: .white, rng: &rng)
                if let result = noisy.withUnsafeBufferPointer({ yin.estimate($0) }),
                    abs(cents(result.frequency, relativeTo: truth)) > 600
                {
                    errors += 1
                }
            }
            return errors
        }
        XCTAssertLessThan(octaveErrors(margin: 0.1), octaveErrors(margin: 0))
    }
}
