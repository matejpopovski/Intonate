import IntonateSynth
import XCTest

@testable import IntonateDSP

final class SpectrumAnalyzerTests: XCTestCase {
    private let sampleRate = 44_100.0
    private let fftSize = 4_096

    private func analyzer() -> SpectrumAnalyzer {
        SpectrumAnalyzer(fftSize: fftSize, sampleRate: sampleRate, bandMap: .waterfall)
    }

    private func sine(frequency: Double, amplitude: Float = 1, count: Int? = nil) -> [Float] {
        (0..<(count ?? fftSize)).map { amplitude * Float(sin(2 * .pi * frequency * Double($0) / sampleRate)) }
    }

    private func powerSpectrum(_ signal: [Float]) -> [Float] {
        var spectrum = [Float](repeating: 0, count: fftSize / 2 + 1)
        analyzer().powerSpectrum(signal, into: &spectrum)
        return spectrum
    }

    func testFullScaleSineOnABinReadsUnity() {
        let binWidth = sampleRate / Double(fftSize)
        let spectrum = powerSpectrum(sine(frequency: binWidth * 100))
        XCTAssertEqual(spectrum[100], 1, accuracy: 1e-3)
    }

    func testAmplitudeCalibrationIsLinear() {
        let binWidth = sampleRate / Double(fftSize)
        let spectrum = powerSpectrum(sine(frequency: binWidth * 64, amplitude: 0.1))
        XCTAssertEqual(10 * log10(spectrum[64]), -20, accuracy: 0.05)
    }

    func testHannSidelobesFallBelowForty() {
        // Halfway between bins: the worst case for leakage.
        let binWidth = sampleRate / Double(fftSize)
        let spectrum = powerSpectrum(sine(frequency: binWidth * 200.5))
        let peak = spectrum.max() ?? 0
        XCTAssertEqual(spectrum.firstIndex(of: peak).map { abs($0 - 200) <= 1 }, true)
        let distant = spectrum[250...300].max() ?? 0
        XCTAssertLessThan(10 * log10(distant / peak), -40)
    }

    func testSilenceIsAtTheFloorInEveryBand() {
        let analyzer = analyzer()
        var bands = [Float](repeating: 1, count: analyzer.bandMap.bandCount)
        analyzer.process([Float](repeating: 0, count: fftSize), into: &bands)
        XCTAssertEqual(bands.max(), 0)
    }

    func testToneAppearsInTheBandNearestItsFrequency() {
        let analyzer = analyzer()
        var bands = [Float](repeating: 0, count: analyzer.bandMap.bandCount)
        for frequency in [110.0, 220, 440, 880, 1_760, 3_520] {
            analyzer.process(sine(frequency: frequency, amplitude: 0.5), into: &bands)
            let peakBand = bands.indices.max { bands[$0] < bands[$1] }!
            let expected = analyzer.bandMap.bandPosition(frequency: frequency)
            XCTAssertEqual(Double(peakBand), expected, accuracy: 2.5, "\(frequency) Hz")
        }
    }

    func testBandMapIsLogarithmicAndInvertible() {
        let map = LogBandMap.waterfall
        let octaves = log2(map.maxFrequency / map.minFrequency)
        let bandsPerOctave = Double(map.bandCount - 1) / octaves
        let oneOctaveUp = map.centerFrequency(band: Int(bandsPerOctave.rounded()))
        XCTAssertEqual(oneOctaveUp / map.minFrequency, 2, accuracy: 0.01)
        for band in stride(from: 0, to: map.bandCount, by: 37) {
            XCTAssertEqual(map.bandPosition(frequency: map.centerFrequency(band: band)), Double(band), accuracy: 1e-9)
        }
    }

    /// A voice has several harmonics; each should stand clear of the valley between them.
    func testHarmonicsOfAVoiceAreResolvedInTheWaterfall() {
        let signal = VoiceSynth.clip(contour: .constant(220), duration: 0.1, sampleRate: sampleRate, timbre: .bright)
        let analyzer = analyzer()
        var bands = [Float](repeating: 0, count: analyzer.bandMap.bandCount)
        analyzer.process(signal, into: &bands)
        let map = analyzer.bandMap
        for harmonic in 1...5 {
            let onPeak = bands[Int(map.bandPosition(frequency: 220 * Double(harmonic)).rounded())]
            let between = bands[Int(map.bandPosition(frequency: 220 * (Double(harmonic) + 0.5)).rounded())]
            XCTAssertGreaterThan(onPeak, between + 0.1, "harmonic \(harmonic)")
        }
    }
}
