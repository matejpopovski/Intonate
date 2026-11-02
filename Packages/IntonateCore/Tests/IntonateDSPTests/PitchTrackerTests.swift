import XCTest

@testable import IntonateDSP

final class PitchTrackerTests: XCTestCase {
    private func voiced(_ frequency: Double, aperiodicity: Float = 0.02) -> PitchEstimate {
        PitchEstimate(frequency: frequency, lag: 44_100 / frequency, aperiodicity: aperiodicity, isPeriodic: true)
    }

    func testSingleOctaveGlitchIsRemovedByTheMedian() {
        var tracker = PitchTracker()
        var outputs: [Double?] = []
        for frequency in [220.0, 220, 220, 440, 220, 220, 220] {
            outputs.append(tracker.push(estimate: voiced(frequency), time: 0, levelDB: -20).frequency)
        }
        for output in outputs.compactMap({ $0 }) {
            XCTAssertEqual(output, 220, accuracy: 1e-6)
        }
    }

    func testPitchIsWithheldUntilTheOnsetRunCompletes() {
        var tracker = PitchTracker(configuration: PitchTrackerConfiguration(onsetFrames: 3))
        XCTAssertNil(tracker.push(estimate: voiced(220), time: 0, levelDB: -20).frequency)
        XCTAssertNil(tracker.push(estimate: voiced(220), time: 0, levelDB: -20).frequency)
        XCTAssertNotNil(tracker.push(estimate: voiced(220), time: 0, levelDB: -20).frequency)
    }

    func testQuietFramesAreUnvoiced() {
        var tracker = PitchTracker()
        for _ in 0..<5 {
            XCTAssertNil(tracker.push(estimate: voiced(220), time: 0, levelDB: -70).frequency)
        }
    }

    func testVoicingDoesNotRequireCrossingTheDetectorThreshold() {
        // The detector's dip threshold picks a lag; whether someone is singing is the tracker's call.
        var tracker = PitchTracker(configuration: PitchTrackerConfiguration(onsetFrames: 1))
        let breathy = PitchEstimate(frequency: 220, lag: 200, aperiodicity: 0.2, isPeriodic: false)
        XCTAssertNotNil(tracker.push(estimate: breathy, time: 0, levelDB: -20).frequency)
    }

    func testAperiodicFramesAreUnvoicedAndBreakTheRun() {
        var tracker = PitchTracker(configuration: PitchTrackerConfiguration(onsetFrames: 2))
        _ = tracker.push(estimate: voiced(220), time: 0, levelDB: -20)
        XCTAssertNotNil(tracker.push(estimate: voiced(220), time: 0, levelDB: -20).frequency)
        XCTAssertNil(tracker.push(estimate: voiced(220, aperiodicity: 0.6), time: 0, levelDB: -20).frequency)
        XCTAssertNil(tracker.push(estimate: voiced(220), time: 0, levelDB: -20).frequency, "the run restarted")
    }

    func testAnUnvoicedGapStopsAnOldNoteFromLeakingIntoTheNext() {
        var tracker = PitchTracker(configuration: PitchTrackerConfiguration(onsetFrames: 1))
        for _ in 0..<5 {
            _ = tracker.push(estimate: voiced(220), time: 0, levelDB: -20)
        }
        _ = tracker.push(estimate: nil, time: 0, levelDB: -20)
        let next = tracker.push(estimate: voiced(330), time: 0, levelDB: -20)
        XCTAssertEqual(next.frequency ?? 0, 330, accuracy: 1e-6)
    }

    func testVoicedTimeIsTheMiddleOfTheMedianWindow() {
        var tracker = PitchTracker(configuration: PitchTrackerConfiguration(onsetFrames: 1, medianFrames: 5))
        var last = 0.0
        for step in 0..<8 {
            last = tracker.push(estimate: voiced(220), time: Double(step), levelDB: -20).time
        }
        XCTAssertEqual(last, 5)
    }

    func testMedianOfAnEvenPartialRunPicksTheLowerMiddle() {
        var tracker = PitchTracker(configuration: PitchTrackerConfiguration(onsetFrames: 1))
        _ = tracker.push(estimate: voiced(200), time: 0, levelDB: -20)
        let second = tracker.push(estimate: voiced(400), time: 0, levelDB: -20)
        XCTAssertEqual(second.frequency ?? 0, 200, accuracy: 1e-6)
    }
}
