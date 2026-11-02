import IntonateDSP
import XCTest

@testable import IntonateTraining

final class PerformanceScorerTests: XCTestCase {
    private let exercise = Exercise(
        id: "test",
        numeral: "T",
        title: "Test",
        summary: "",
        tempo: 60,
        steps: [Exercise.Step(0), Exercise.Step(2), Exercise.Step(4)]
    )
    private var timeline: ExerciseTimeline { ExerciseTimeline(exercise: exercise, tonicMidi: 60) }

    /// Feeds frames every 5 ms with `pitch` giving the sung frequency for a target, or nil for silence.
    private func perform(_ pitch: (TimedNote) -> Double?) -> PerformanceReport {
        var scorer = PerformanceScorer(timeline: timeline)
        var time = 0.0
        while time < timeline.duration {
            let note = timeline.note(at: time)!
            let frame = PitchFrame(time: time, frequency: pitch(note), rawFrequency: nil, aperiodicity: 0, levelDB: -20)
            scorer.add(frame, at: time)
            time += 0.005
        }
        return scorer.report()
    }

    private func sung(_ note: TimedNote, offsetCents: Double) -> Double {
        timeline.frequency(of: note) * pow(2, offsetCents / 1200)
    }

    func testPerfectPerformanceScoresFullMarks() {
        let report = perform { self.sung($0, offsetCents: 0) }
        XCTAssertEqual(report.score, 100, accuracy: 1e-6)
        XCTAssertEqual(report.inTuneFraction, 1, accuracy: 1e-6)
        XCTAssertEqual(report.meanAbsoluteCents ?? -1, 0, accuracy: 1e-6)
    }

    func testSilenceScoresZero() {
        let report = perform { _ in nil }
        XCTAssertEqual(report.score, 0)
        XCTAssertNil(report.meanAbsoluteCents)
        XCTAssertNil(report.tendencyCents)
        for note in report.notes {
            XCTAssertEqual(note.voicedFraction, 0)
            XCTAssertNil(note.meanCents)
        }
    }

    func testMarksFallLinearlyBetweenTheTwoLines() {
        let rules = ScoringRules()
        XCTAssertEqual(rules.marks(forError: 0), 1)
        XCTAssertEqual(rules.marks(forError: rules.fullMarksCents), 1)
        XCTAssertEqual(rules.marks(forError: (rules.fullMarksCents + rules.zeroMarksCents) / 2), 0.5, accuracy: 1e-9)
        XCTAssertEqual(rules.marks(forError: rules.zeroMarksCents), 0)
        XCTAssertEqual(rules.marks(forError: 500), 0)
    }

    func testAFlatSingerIsScoredAndTheTendencyIsReported() {
        let report = perform { self.sung($0, offsetCents: -30) }
        XCTAssertEqual(report.tendencyCents ?? 0, -30, accuracy: 0.01)
        XCTAssertEqual(report.score, 100 * 20 / 35, accuracy: 0.1)
        XCTAssertEqual(report.inTuneFraction, 0, accuracy: 1e-9)
    }

    func testOneBadNoteLowersOnlyThatNote() {
        let report = perform { note in
            self.sung(note, offsetCents: note.index == 1 ? 80 : 0)
        }
        XCTAssertEqual(report.notes[0].score, 100, accuracy: 1e-6)
        XCTAssertEqual(report.notes[1].score, 0, accuracy: 1e-6)
        XCTAssertEqual(report.notes[2].score, 100, accuracy: 1e-6)
        XCTAssertEqual(report.score, 100 * 2 / 3, accuracy: 0.01)
    }

    func testAttackScoopInsideTheGraceWindowIsForgiven() {
        var scorer = PerformanceScorer(timeline: timeline)
        var time = 0.0
        while time < timeline.duration {
            let note = timeline.note(at: time)!
            let intoNote = time - note.start
            let offset = intoNote < 0.1 ? -300.0 : 0
            scorer.add(
                PitchFrame(
                    time: time,
                    frequency: sung(note, offsetCents: offset),
                    rawFrequency: nil,
                    aperiodicity: 0,
                    levelDB: -20
                ),
                at: time
            )
            time += 0.005
        }
        XCTAssertEqual(scorer.report().score, 100, accuracy: 1e-6)
    }

    func testSpreadMeasuresWobbleNotOffset() {
        var scorer = PerformanceScorer(timeline: timeline)
        var time = 0.0
        var flip = false
        while time < 1 {
            let note = timeline.notes[0]
            flip.toggle()
            let frequency = sung(note, offsetCents: flip ? 10 : 30)
            scorer.add(
                PitchFrame(time: time, frequency: frequency, rawFrequency: nil, aperiodicity: 0, levelDB: -20),
                at: time
            )
            time += 0.005
        }
        let result = scorer.report().notes[0]
        XCTAssertEqual(result.meanCents ?? 0, 20, accuracy: 0.5)
        XCTAssertEqual(result.spreadCents ?? 0, 10, accuracy: 0.5)
    }

    func testFramesOutsideTheExerciseAreIgnored() {
        var scorer = PerformanceScorer(timeline: timeline)
        let frame = PitchFrame(time: 0, frequency: 440, rawFrequency: nil, aperiodicity: 0, levelDB: -20)
        scorer.add(frame, at: -1)
        scorer.add(frame, at: timeline.duration + 1)
        XCTAssertEqual(scorer.report().notes.map(\.voicedFraction), [0, 0, 0])
    }
}
