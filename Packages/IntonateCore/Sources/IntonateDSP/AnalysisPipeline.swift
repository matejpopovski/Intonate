import Accelerate
import Foundation

public struct AnalysisConfiguration: Sendable, Equatable {
    public var yin: YINConfiguration
    public var tracker: PitchTrackerConfiguration
    /// Samples between pitch estimates.
    public var pitchHop: Int
    /// Samples between waterfall columns.
    public var columnHop: Int
    public var fftSize: Int
    public var bandMap: LogBandMap

    public init(
        sampleRate: Double = 44_100,
        yin: YINConfiguration? = nil,
        tracker: PitchTrackerConfiguration = PitchTrackerConfiguration(),
        pitchHop: Int? = nil,
        columnHop: Int? = nil,
        fftSize: Int? = nil,
        bandMap: LogBandMap = .waterfall
    ) {
        self.yin = yin ?? YINConfiguration(sampleRate: sampleRate)
        self.tracker = tracker
        // Durations are fixed and sample counts follow, so a 48 kHz route behaves like a 44.1 kHz one.
        self.pitchHop = pitchHop ?? Int((0.0058 * sampleRate).rounded())
        self.columnHop = columnHop ?? Int((0.0116 * sampleRate).rounded())
        self.fftSize = fftSize ?? (sampleRate > 60_000 ? 8_192 : 4_096)
        self.bandMap = bandMap
    }

    public var sampleRate: Double { yin.sampleRate }
}

/// The chain from raw samples to pitch frames and waterfall columns. It is the same code under the
/// microphone, the demo voice, the unit tests and the benchmarks, so that a measured number describes
/// what the app does. It holds no clock: time comes only from counting samples.
public final class AnalysisPipeline {
    public let configuration: AnalysisConfiguration
    public let bandCount: Int

    private let detector: YINDetector
    private var tracker: PitchTracker
    private let spectrum: SpectrumAnalyzer

    private let historyLength: Int
    /// Twice the history, so that the latest `historyLength` samples are always contiguous and a
    /// frame can be handed to the detector without copying it out of a ring.
    private var history: [Float]
    private var writePosition: Int
    private var bands: [Float]

    private var samplesSeen: Int64 = 0
    private var nextPitchAt: Int64
    private var nextColumnAt: Int64

    public init(configuration: AnalysisConfiguration = AnalysisConfiguration()) {
        self.configuration = configuration
        detector = YINDetector(configuration: configuration.yin)
        tracker = PitchTracker(configuration: configuration.tracker)
        spectrum = SpectrumAnalyzer(
            fftSize: configuration.fftSize,
            sampleRate: configuration.sampleRate,
            bandMap: configuration.bandMap
        )
        bandCount = configuration.bandMap.bandCount
        historyLength = max(configuration.yin.requiredSamples, configuration.fftSize)
        history = [Float](repeating: 0, count: historyLength * 2)
        writePosition = historyLength
        bands = [Float](repeating: 0, count: configuration.bandMap.bandCount)
        nextPitchAt = Int64(configuration.yin.requiredSamples)
        nextColumnAt = Int64(configuration.fftSize)
    }

    /// Clears all state and restarts the stream clock at zero.
    public func reset() {
        tracker.reset()
        history.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
        writePosition = historyLength
        samplesSeen = 0
        nextPitchAt = Int64(configuration.yin.requiredSamples)
        nextColumnAt = Int64(configuration.fftSize)
    }

    /// Samples consumed so far. Frame emission happens at sample accuracy against this count, whatever
    /// the chunk size, which is what makes the latency measurements deterministic.
    public var sampleCount: Int64 { samplesSeen }

    /// Feeds any number of samples and calls back for each frame that becomes due.
    public func process(
        _ samples: UnsafeBufferPointer<Float>,
        onPitch: (PitchFrame) -> Void,
        onColumn: (UnsafeBufferPointer<Float>) -> Void
    ) {
        var offset = 0
        while offset < samples.count {
            let untilNext = Int(min(nextPitchAt, nextColumnAt) - samplesSeen)
            let count = min(untilNext, samples.count - offset)
            append(samples.baseAddress! + offset, count: count)
            offset += count
            if samplesSeen == nextPitchAt {
                onPitch(pitchFrame())
                nextPitchAt += Int64(configuration.pitchHop)
            }
            if samplesSeen == nextColumnAt {
                computeColumn()
                bands.withUnsafeBufferPointer(onColumn)
                nextColumnAt += Int64(configuration.columnHop)
            }
        }
    }

    private func append(_ source: UnsafePointer<Float>, count: Int) {
        var remaining = count
        var input = source
        while remaining > 0 {
            if writePosition == historyLength * 2 {
                history.withUnsafeMutableBufferPointer { buffer in
                    let base = buffer.baseAddress!
                    base.update(from: base + historyLength, count: historyLength)
                }
                writePosition = historyLength
            }
            let run = min(remaining, historyLength * 2 - writePosition)
            history.withUnsafeMutableBufferPointer { buffer in
                (buffer.baseAddress! + writePosition).update(from: input, count: run)
            }
            writePosition += run
            input += run
            remaining -= run
        }
        samplesSeen += Int64(count)
    }

    private func pitchFrame() -> PitchFrame {
        let yin = configuration.yin
        let required = yin.requiredSamples
        return history.withUnsafeBufferPointer { buffer in
            let frame = UnsafeBufferPointer(rebasing: buffer[(writePosition - required)..<writePosition])
            let estimate = detector.estimate(frame)

            var meanSquare: Float = 0
            vDSP_measqv(frame.baseAddress!, 1, &meanSquare, vDSP_Length(required))
            let levelDB = 10 * log10(max(meanSquare, 1e-12))

            // YIN compares x[j] with x[j + τ], so the estimate is centred on the middle of the
            // compared span, which depends on the period found, not on the end of the buffer.
            let lag = estimate?.lag ?? 0
            let centerOffset = (Double(yin.windowLength) + lag) / 2
            let frameStart = Double(samplesSeen - Int64(required))
            let time = (frameStart + centerOffset) / yin.sampleRate
            return tracker.push(estimate: estimate, time: time, levelDB: levelDB)
        }
    }

    private func computeColumn() {
        history.withUnsafeBufferPointer { buffer in
            let start = buffer.baseAddress! + (writePosition - configuration.fftSize)
            bands.withUnsafeMutableBufferPointer { output in
                spectrum.process(start, into: output.baseAddress!)
            }
        }
    }
}
