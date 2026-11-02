import IntonateSynth
import XCTest

@testable import IntonateDSP

final class ToneGeneratorTests: XCTestCase {
    private let sampleRate = 44_100.0

    private func render(_ tone: ToneGenerator, count: Int) -> [Float] {
        var output = [Float](repeating: 0, count: count)
        tone.render(into: &output, count: count)
        return output
    }

    func testSilentUntilAPitchIsSet() {
        let tone = ToneGenerator(sampleRate: sampleRate)
        XCTAssertEqual(render(tone, count: 512).max(), 0)
    }

    func testDetectorHearsTheRequestedPitch() throws {
        let tone = ToneGenerator(sampleRate: sampleRate)
        tone.setFrequency(196)
        _ = render(tone, count: 4_096)
        let detector = YINDetector()
        let signal = render(tone, count: detector.configuration.requiredSamples)
        let estimate = try XCTUnwrap(signal.withUnsafeBufferPointer { detector.estimate($0) })
        XCTAssertEqual(cents(estimate.frequency, relativeTo: 196), 0, accuracy: 1)
    }

    func testStartAndStopRampInsteadOfClicking() {
        let tone = ToneGenerator(sampleRate: sampleRate)
        tone.setFrequency(440)
        var signal = render(tone, count: 2_048)
        tone.setFrequency(nil)
        signal += render(tone, count: 2_048)
        var largestJump: Float = 0
        for (a, b) in zip(signal, signal.dropFirst()) {
            largestJump = max(largestJump, abs(b - a))
        }
        XCTAssertLessThan(largestJump, 0.08)
        XCTAssertEqual(signal.last, 0, "must fade fully out")
    }
}
