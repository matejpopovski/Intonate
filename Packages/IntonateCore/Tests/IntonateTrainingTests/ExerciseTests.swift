import IntonateDSP
import XCTest

@testable import IntonateTraining

final class ExerciseTests: XCTestCase {
    private let scale = Exercise.programme[1]

    func testTimelineUsesTempoAndBeats() {
        let timeline = ExerciseTimeline(exercise: scale, tonicMidi: 60)
        let secondsPerNote = 60 / scale.tempo * 2
        XCTAssertEqual(timeline.notes.count, scale.steps.count)
        XCTAssertEqual(timeline.notes[3].start, 3 * secondsPerNote, accuracy: 1e-9)
        XCTAssertEqual(timeline.duration, Double(scale.steps.count) * secondsPerNote, accuracy: 1e-9)
    }

    func testTransposingMovesEveryNote() {
        let low = ExerciseTimeline(exercise: scale, tonicMidi: 48)
        let high = ExerciseTimeline(exercise: scale, tonicMidi: 60)
        for (a, b) in zip(low.notes, high.notes) {
            XCTAssertEqual(b.midi - a.midi, 12)
        }
    }

    func testNoteLookupHandlesEdges() {
        let timeline = ExerciseTimeline(exercise: scale, tonicMidi: 60)
        XCTAssertNil(timeline.note(at: -0.01))
        XCTAssertEqual(timeline.note(at: 0)?.index, 0)
        XCTAssertEqual(timeline.note(at: timeline.notes[1].start)?.index, 1)
        XCTAssertEqual(timeline.note(at: timeline.notes[1].start - 1e-6)?.index, 0)
        XCTAssertEqual(timeline.note(at: timeline.duration - 1e-6)?.index, scale.steps.count - 1)
        XCTAssertNil(timeline.note(at: timeline.duration))
    }

    func testEveryExerciseFitsTheDetectorRangeForEveryVoice() {
        let tuning = Tuning.standard
        for exercise in Exercise.programme {
            for voice in VoiceRange.allCases {
                let timeline = ExerciseTimeline(exercise: exercise, tonicMidi: voice.tonicMidi)
                for note in timeline.notes {
                    let frequency = tuning.frequency(midi: Double(note.midi))
                    XCTAssertGreaterThan(frequency, 80, "\(exercise.title) \(voice)")
                    XCTAssertLessThan(frequency, 1_100, "\(exercise.title) \(voice)")
                }
            }
        }
    }
}
