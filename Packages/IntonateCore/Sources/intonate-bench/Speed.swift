import Foundation
import IntonateDSP
import IntonateSynth

struct SpeedRow: Encodable {
    let label: String
    let iterations: Int
    let p50Microseconds: Double
    let p99Microseconds: Double
    let budgetShare: Double
}

struct SpeedReport: Encodable {
    let host: HostInfo
    let budgetMicroseconds: Double
    let budgetNote: String
    let rows: [SpeedRow]
    let realTimeFactor: Double
}

/// Timing of `body` per call, in microseconds. Short loops repeated many times, so a preempted
/// iteration shows up in p99 and does not shift the median.
private func timed(iterations: Int, _ body: () -> Void) -> [Double] {
    var samples = [Double](repeating: 0, count: iterations)
    for index in 0..<iterations {
        let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        body()
        samples[index] = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) / 1_000
    }
    return samples.sorted()
}

func runSpeed(output: URL) throws {
    let configuration = AnalysisConfiguration()
    let rate = configuration.sampleRate
    let clean = VoiceSynth.clip(contour: .constant(220), duration: 0.5, sampleRate: rate, timbre: .vowelAh)
    var rng = SplitMix64(seed: 41)
    let signal = Signal.mix(clean, snrDB: 30, kind: .white, rng: &rng)
    let hopMicroseconds = Double(configuration.pitchHop) / rate * 1_000_000

    func row(_ label: String, iterations: Int = 30_000, _ body: () -> Void) -> SpeedRow {
        // Warm caches and page in buffers before measuring.
        for _ in 0..<500 { body() }
        let samples = timed(iterations: iterations, body)
        let median = percentile(samples, 0.5)
        return SpeedRow(
            label: label,
            iterations: iterations,
            p50Microseconds: rounded(median, 2),
            p99Microseconds: rounded(percentile(samples, 0.99), 2),
            budgetShare: rounded(median / hopMicroseconds, 4)
        )
    }

    var rows: [SpeedRow] = []
    for method in YINConfiguration.DifferenceMethod.allCases {
        for samples in [1_024, 2_048] {
            let yin = YINDetector(configuration: YINConfiguration(windowLength: samples, difference: method))
            rows.append(
                signal.withUnsafeBufferPointer { buffer in
                    row("YIN \(method.rawValue), W=\(samples)") {
                        _ = yin.estimate(buffer)
                    }
                }
            )
        }
    }

    let analyzer = SpectrumAnalyzer(fftSize: configuration.fftSize, sampleRate: rate, bandMap: configuration.bandMap)
    var bands = [Float](repeating: 0, count: configuration.bandMap.bandCount)
    rows.append(
        signal.withUnsafeBufferPointer { buffer in
            bands.withUnsafeMutableBufferPointer { output in
                row("spectrum, \(configuration.fftSize)-point FFT to \(configuration.bandMap.bandCount) bands") {
                    analyzer.process(buffer.baseAddress!, into: output.baseAddress!)
                }
            }
        }
    )

    let pipeline = AnalysisPipeline(configuration: configuration)
    let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    var frames = 0
    var processed = 0
    for _ in 0..<40 {
        signal.withUnsafeBufferPointer { buffer in
            pipeline.process(buffer, onPitch: { _ in frames += 1 }, onColumn: { _ in })
        }
        processed += signal.count
    }
    let elapsed = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) / 1e9
    let audioSeconds = Double(processed) / rate

    try writeJSON(
        SpeedReport(
            host: .current(note: "native macOS release build on one core, not a phone and not the simulator"),
            budgetMicroseconds: rounded(hopMicroseconds, 1),
            budgetNote: "budgetShare is the p50 as a fraction of one pitch hop, the real-time deadline",
            rows: rows,
            realTimeFactor: rounded(audioSeconds / elapsed, 1)
        ),
        to: output.appendingPathComponent("compute_host.json")
    )
}
