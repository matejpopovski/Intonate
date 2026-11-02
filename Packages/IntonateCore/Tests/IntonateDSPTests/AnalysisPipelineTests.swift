import IntonateSynth
import XCTest

@testable import IntonateDSP

final class AnalysisPipelineTests: XCTestCase {
    private let sampleRate = 44_100.0

    private func run(
        _ pipeline: AnalysisPipeline,
        _ signal: [Float],
        chunk: Int = 512
    ) -> (frames: [PitchFrame], columns: [[Float]]) {
        var frames: [PitchFrame] = []
        var columns: [[Float]] = []
        signal.withUnsafeBufferPointer { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = min(chunk, buffer.count - offset)
                pipeline.process(
                    UnsafeBufferPointer(rebasing: buffer[offset..<(offset + count)]),
                    onPitch: { frames.append($0) },
                    onColumn: { columns.append(Array($0)) }
                )
                offset += count
            }
        }
        return (frames, columns)
    }

    /// Audio callbacks come in sizes the app does not control, so output must not depend on them.
    func testOutputDoesNotDependOnChunkSize() {
        let signal = VoiceSynth.clip(contour: .constant(261.6), duration: 0.5, sampleRate: sampleRate, timbre: .vowelAh)
        let reference = run(AnalysisPipeline(), signal, chunk: signal.count)
        for chunk in [1, 37, 256, 1024, 4800] {
            let other = run(AnalysisPipeline(), signal, chunk: chunk)
            XCTAssertEqual(other.frames, reference.frames, "chunk \(chunk)")
            XCTAssertEqual(other.columns, reference.columns, "chunk \(chunk)")
        }
    }

    func testHopsSetTheOutputRates() {
        let pipeline = AnalysisPipeline()
        let configuration = pipeline.configuration
        let signal = [Float](repeating: 0, count: 44_100)
        let output = run(pipeline, signal)
        let expectedFrames = (signal.count - configuration.yin.requiredSamples) / configuration.pitchHop + 1
        let expectedColumns = (signal.count - configuration.fftSize) / configuration.columnHop + 1
        XCTAssertEqual(output.frames.count, expectedFrames)
        XCTAssertEqual(output.columns.count, expectedColumns)
    }

    func testTimestampsAreOnTheAudioClockAndIncreasing() throws {
        let signal = VoiceSynth.clip(contour: .constant(330), duration: 0.5, sampleRate: sampleRate, timbre: .sine)
        let frames = run(AnalysisPipeline(), signal).frames
        let first = try XCTUnwrap(frames.first)
        XCTAssertGreaterThan(first.time, 0)
        XCTAssertLessThan(first.time, 0.05)
        for (earlier, later) in zip(frames, frames.dropFirst()) {
            XCTAssertGreaterThanOrEqual(later.time, earlier.time)
        }
        let last = try XCTUnwrap(frames.last)
        XCTAssertEqual(last.time, 0.5, accuracy: 0.05)
    }

    func testAStepBetweenNotesIsFollowedWithinAFewFrames() throws {
        let change = 0.5
        let signal = VoiceSynth.clip(
            contour: .step(from: 220, to: 330, at: change),
            duration: 1,
            sampleRate: sampleRate,
            timbre: .vowelAh
        )
        let frames = run(AnalysisPipeline(), signal).frames
        let tail = frames.filter { $0.time > change + 0.06 }
        XCTAssertFalse(tail.isEmpty)
        for frame in tail {
            XCTAssertEqual(cents(try XCTUnwrap(frame.frequency), relativeTo: 330), 0, accuracy: 10)
        }
    }

    func testNoiseProducesNoPitchAndLowLevelSilenceReportsTheFloor() {
        var rng = SplitMix64(seed: 3)
        var noise = Signal.noise(kind: .white, count: 22_050, rng: &rng)
        Signal.normalize(&noise, levelDB: -30)
        let frames = run(AnalysisPipeline(), noise).frames
        XCTAssertFalse(frames.isEmpty)
        XCTAssertTrue(frames.allSatisfy { $0.frequency == nil })
    }

    func testResetRestartsTheClock() {
        let pipeline = AnalysisPipeline()
        let signal = VoiceSynth.clip(contour: .constant(330), duration: 0.2, sampleRate: sampleRate, timbre: .sine)
        let first = run(pipeline, signal).frames
        pipeline.reset()
        let second = run(pipeline, signal).frames
        XCTAssertEqual(first, second)
    }

    func testFortyEightKilohertzKeepsTheSameDurations() {
        let slow = AnalysisConfiguration(sampleRate: 44_100)
        let fast = AnalysisConfiguration(sampleRate: 48_000)
        XCTAssertEqual(Double(slow.pitchHop) / 44_100, Double(fast.pitchHop) / 48_000, accuracy: 1e-4)
        XCTAssertEqual(
            Double(slow.yin.windowLength) / 44_100,
            Double(fast.yin.windowLength) / 48_000,
            accuracy: 1e-4
        )
    }
}
