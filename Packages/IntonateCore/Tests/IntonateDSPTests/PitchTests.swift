import XCTest

@testable import IntonateDSP

final class PitchTests: XCTestCase {
    func testConcertAIsMidi69() {
        XCTAssertEqual(Tuning.standard.frequency(midi: 69), 440, accuracy: 1e-9)
        XCTAssertEqual(Tuning.standard.midi(frequency: 440), 69, accuracy: 1e-9)
    }

    func testFrequencyAndMidiAreInverses() {
        for midi in stride(from: 24.0, through: 96.0, by: 0.37) {
            let frequency = Tuning.standard.frequency(midi: midi)
            XCTAssertEqual(Tuning.standard.midi(frequency: frequency), midi, accuracy: 1e-9)
        }
    }

    func testAlternativeConcertPitchShiftsEverything() {
        let baroque = Tuning(concertA: 415)
        XCTAssertEqual(baroque.frequency(midi: 69), 415, accuracy: 1e-9)
        XCTAssertEqual(
            cents(baroque.frequency(midi: 60), relativeTo: Tuning.standard.frequency(midi: 60)),
            -101.3,
            accuracy: 0.1
        )
    }

    func testCentsAreSignedAndOctaveIs1200() {
        XCTAssertEqual(cents(880, relativeTo: 440), 1200, accuracy: 1e-9)
        XCTAssertEqual(cents(220, relativeTo: 440), -1200, accuracy: 1e-9)
    }

    func testNoteNamesUseScientificPitchNotation() {
        XCTAssertEqual(NoteName(midi: 60).description, "C4")
        XCTAssertEqual(NoteName(midi: 69).description, "A4")
        XCTAssertEqual(NoteName(midi: 36).description, "C2")
        XCTAssertEqual(NoteName(midi: 70).description, "B♭4")
        XCTAssertEqual(NoteName(midi: 11).description, "B-1")
    }
}
