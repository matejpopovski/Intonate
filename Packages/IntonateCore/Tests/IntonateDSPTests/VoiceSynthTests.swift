import XCTest

@testable import IntonateDSP
@testable import IntonateSynth

/// The accuracy figures are only as good as these signals, so the generators get tests of their own.
final class VoiceSynthTests: XCTestCase {
    private let sampleRate = 44_100.0

    func testClipsHaveTheRequestedLevel() {
        let clip = VoiceSynth.clip(
            contour: .constant(220),
            duration: 0.25,
            sampleRate: sampleRate,
            timbre: .vowelAh,
            levelDB: -18
        )
        XCTAssertEqual(20 * log10(Signal.rms(clip)), -18, accuracy: 0.01)
    }

    func testSameSeedSameSignalDifferentSeedDifferentSignal() {
        let a = VoiceSynth.clip(
            contour: .constant(220),
            duration: 0.05,
            sampleRate: sampleRate,
            timbre: .bright,
            seed: 1
        )
        let b = VoiceSynth.clip(
            contour: .constant(220),
            duration: 0.05,
            sampleRate: sampleRate,
            timbre: .bright,
            seed: 1
        )
        let c = VoiceSynth.clip(
            contour: .constant(220),
            duration: 0.05,
            sampleRate: sampleRate,
            timbre: .bright,
            seed: 2
        )
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testMixHitsTheRequestedSNR() {
        let clean = VoiceSynth.clip(contour: .constant(220), duration: 0.5, sampleRate: sampleRate, timbre: .vowelAh)
        for kind in NoiseKind.allCases {
            var rng = SplitMix64(seed: 5)
            let noisy = Signal.mix(clean, snrDB: 10, kind: kind, rng: &rng)
            let residual = zip(noisy, clean).map { $0 - $1 }
            XCTAssertEqual(20 * log10(Signal.rms(clean) / Signal.rms(residual)), 10, accuracy: 0.01, "\(kind)")
        }
    }

    func testPinkNoiseFallsAboutThreeDecibelsPerOctave() {
        var rng = SplitMix64(seed: 9)
        let fftSize = 4_096
        let analyzer = SpectrumAnalyzer(fftSize: fftSize, sampleRate: sampleRate, bandMap: .waterfall)
        var average = [Float](repeating: 0, count: fftSize / 2 + 1)
        var frame = [Float](repeating: 0, count: fftSize / 2 + 1)
        let noise = Signal.noise(kind: .pink, count: fftSize * 64, rng: &rng)
        for start in stride(from: 0, to: noise.count - fftSize, by: fftSize) {
            noise.withUnsafeBufferPointer { analyzer.powerSpectrum($0.baseAddress! + start, into: &frame) }
            for index in average.indices { average[index] += frame[index] }
        }
        // 500 Hz to 8 kHz is four octaves and should fall about 12 dB.
        let low = average[46...47].reduce(0, +)
        let high = average[740...760].reduce(0, +) / 10.5
        XCTAssertEqual(10 * log10(low / high), 12, accuracy: 2.5)
    }

    func testSpectrumOfASteadyToneHasEnergyOnlyAtHarmonics() {
        let f0 = sampleRate / 4_096 * 20
        let clip = VoiceSynth.clip(contour: .constant(f0), duration: 0.1, sampleRate: sampleRate, timbre: .bright)
        let analyzer = SpectrumAnalyzer(fftSize: 4_096, sampleRate: sampleRate, bandMap: .waterfall)
        var spectrum = [Float](repeating: 0, count: 2_049)
        analyzer.powerSpectrum(clip, into: &spectrum)
        XCTAssertGreaterThan(spectrum[20], 1_000 * spectrum[30])
        XCTAssertGreaterThan(spectrum[40], 1_000 * spectrum[50])
    }

    func testVoiceStaysBandLimitedAtTheTopOfTheRange() {
        let f0 = 1_046.5
        let clip = VoiceSynth.clip(contour: .constant(f0), duration: 0.1, sampleRate: sampleRate, timbre: .bright)
        let analyzer = SpectrumAnalyzer(fftSize: 4_096, sampleRate: sampleRate, bandMap: .waterfall)
        var spectrum = [Float](repeating: 0, count: 2_049)
        analyzer.powerSpectrum(clip, into: &spectrum)
        let aboveCutoff = spectrum[1_900...].max() ?? 0
        XCTAssertLessThan(10 * log10(max(aboveCutoff, 1e-20) / (spectrum.max() ?? 1)), -60)
    }

    func testStreamingRenderContinuesPhaseAcrossBlocks() {
        var whole = VoiceSynth(sampleRate: sampleRate, timbre: .vowelEe, seed: 3)
        var split = VoiceSynth(sampleRate: sampleRate, timbre: .vowelEe, seed: 3)
        var a = [Float](repeating: 0, count: 1_000)
        var b = [Float](repeating: 0, count: 1_000)
        whole.render(into: &a, count: 1_000, frequency: { _ in 196 })
        b.withUnsafeMutableBufferPointer { buffer in
            split.render(into: buffer.baseAddress!, count: 317, frequency: { _ in 196 })
            split.render(into: buffer.baseAddress! + 317, count: 683, frequency: { _ in 196 })
        }
        XCTAssertEqual(a, b)
    }
}
