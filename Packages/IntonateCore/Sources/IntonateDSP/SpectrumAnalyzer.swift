import Accelerate
import Foundation

/// Maps FFT bins onto log-spaced bands, so that an octave takes the same height anywhere on the
/// waterfall and a sung interval looks the same in every register.
public struct LogBandMap: Sendable, Equatable {
    public let bandCount: Int
    public let minFrequency: Double
    public let maxFrequency: Double

    public init(bandCount: Int, minFrequency: Double, maxFrequency: Double) {
        precondition(bandCount > 1 && minFrequency > 0 && maxFrequency > minFrequency)
        self.bandCount = bandCount
        self.minFrequency = minFrequency
        self.maxFrequency = maxFrequency
    }

    /// Seven octaves, A1 to A8: the sung range plus the formants above it.
    public static let waterfall = LogBandMap(bandCount: 384, minFrequency: 55, maxFrequency: 7_040)

    public func centerFrequency(band: Int) -> Double {
        minFrequency * pow(maxFrequency / minFrequency, Double(band) / Double(bandCount - 1))
    }

    /// Fractional band position of `frequency`, 0 at the bottom and `bandCount - 1` at the top.
    public func bandPosition(frequency: Double) -> Double {
        log(frequency / minFrequency) / log(maxFrequency / minFrequency) * Double(bandCount - 1)
    }
}

/// Windowed magnitude spectrum on vDSP's real FFT, reduced to log-spaced bands for display.
public final class SpectrumAnalyzer {
    public let fftSize: Int
    public let sampleRate: Double
    public let bandMap: LogBandMap
    /// The level that maps to display intensity 0; 0 dBFS maps to 1.
    public let floorDB: Float

    private let log2Size: vDSP_Length
    private let setup: FFTSetup
    private let window: [Float]
    private var windowed: [Float]
    private var real: [Float]
    private var imag: [Float]
    private var power: [Float]
    private let bandRules: [BandRule]

    /// How one display band reads the spectrum. In the low octaves a band is narrower than a bin and
    /// interpolates between two bins. Higher up a band spans several bins and keeps the peak, because
    /// averaging would dim the narrow vocal harmonics the waterfall is there to show.
    private enum BandRule {
        case interpolate(bin: Int, fraction: Float)
        case peak(first: Int, last: Int)
    }

    public init(fftSize: Int, sampleRate: Double, bandMap: LogBandMap, floorDB: Float = -90) {
        precondition(fftSize > 0 && fftSize & (fftSize - 1) == 0, "FFT size must be a power of two")
        self.fftSize = fftSize
        self.sampleRate = sampleRate
        self.bandMap = bandMap
        self.floorDB = floorDB
        log2Size = vDSP_Length(fftSize.trailingZeroBitCount)
        guard let created = vDSP_create_fftsetup(log2Size, FFTRadix(kFFTRadix2)) else {
            fatalError("vDSP could not allocate an FFT of size \(fftSize)")
        }
        setup = created

        var hann = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&hann, vDSP_Length(fftSize), Int32(vDSP_HANN_DENORM))
        window = hann
        windowed = [Float](repeating: 0, count: fftSize)
        real = [Float](repeating: 0, count: fftSize / 2)
        imag = real
        power = [Float](repeating: 0, count: fftSize / 2 + 1)

        let binWidth = sampleRate / Double(fftSize)
        let lastBin = fftSize / 2
        bandRules = (0..<bandMap.bandCount).map { band in
            let center = bandMap.centerFrequency(band: band)
            let ratio = pow(bandMap.maxFrequency / bandMap.minFrequency, 0.5 / Double(bandMap.bandCount - 1))
            let low = center / ratio / binWidth
            let high = center * ratio / binWidth
            if high - low < 1 {
                let position = min(center / binWidth, Double(lastBin - 1))
                let bin = Int(position)
                return .interpolate(bin: bin, fraction: Float(position - Double(bin)))
            }
            return .peak(first: min(Int(low.rounded()), lastBin), last: min(Int(high.rounded()), lastBin))
        }
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
    }

    /// Fills `spectrum` (fftSize / 2 + 1 values) with the power of each bin, scaled so that a
    /// full-scale sine on a bin centre reads 1.
    public func powerSpectrum(_ samples: UnsafePointer<Float>, into spectrum: UnsafeMutablePointer<Float>) {
        let half = fftSize / 2
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))
        real.withUnsafeMutableBufferPointer { realPointer in
            imag.withUnsafeMutableBufferPointer { imagPointer in
                var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imagPointer.baseAddress!)
                windowed.withUnsafeBufferPointer { input in
                    input.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2Size, FFTDirection(kFFTDirection_Forward))

                // A Hann window has a coherent gain of 0.5, and zrip doubles the transform, so the
                // peak of a unit sine is N/2 and the amplitude is magnitude · 2/N.
                let scale = 2 / Float(fftSize)
                let dc = split.realp[0] * scale / 2
                let nyquist = split.imagp[0] * scale / 2
                spectrum[0] = dc * dc
                spectrum[half] = nyquist * nyquist
                for k in 1..<half {
                    let re = split.realp[k] * scale
                    let im = split.imagp[k] * scale
                    spectrum[k] = re * re + im * im
                }
            }
        }
    }

    /// Writes `bandMap.bandCount` display intensities in 0...1 for the first `fftSize` samples.
    public func process(_ samples: UnsafePointer<Float>, into bands: UnsafeMutablePointer<Float>) {
        power.withUnsafeMutableBufferPointer { spectrum in
            let bins = spectrum.baseAddress!
            powerSpectrum(samples, into: bins)
            let range = -floorDB
            for (band, rule) in bandRules.enumerated() {
                let value: Float
                switch rule {
                case .interpolate(let bin, let fraction):
                    value = bins[bin] + (bins[bin + 1] - bins[bin]) * fraction
                case .peak(let first, let last):
                    var peak: Float = 0
                    vDSP_maxv(bins + first, 1, &peak, vDSP_Length(last - first + 1))
                    value = peak
                }
                let decibels = 10 * log10(max(value, 1e-12))
                bands[band] = max(0, min(1, (decibels - floorDB) / range))
            }
        }
    }
}
