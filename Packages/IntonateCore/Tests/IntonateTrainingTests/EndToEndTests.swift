import IntonateDSP
import IntonateSynth
import XCTest

@testable import IntonateTraining

/// The whole chain: scripted audio through the real analysis pipeline into the real scorer.
final class EndToEndTests: XCTestCase {
    private let sampleRate = 44_100.0

    /// Short on purpose: the additive voice is slow in a debug build and the assertions need few notes.
    private let scale = Exercise(
        id: "short-scale",
        numeral: "T",
        title: "Short scale",
        summary: "",
        tempo: 150,
        steps: [0, 2, 4, 5, 7].map { Exercise.Step($0, beats: 2) }
    )

    private func perform(
        timeline: ExerciseTimeline,
        profile: SingerProfile,
        mistakes: [Int: Double] = [:]
    ) -> (report: PerformanceReport, frames: [PitchFrame], singer: DemoSinger) {
        var singer = DemoSinger(timeline: timeline, profile: profile, sampleRate: sampleRate, mistakes: mistakes)
        let pipeline = AnalysisPipeline(configuration: AnalysisConfiguration(sampleRate: sampleRate))
        var scorer = PerformanceScorer(timeline: timeline)
        var frames: [PitchFrame] = []

        let blockSize = 1_024
        var block = [Float](repeating: 0, count: blockSize)
        var produced = 0
        let total = Int((timeline.duration + 0.2) * sampleRate)
        while produced < total {
            singer.render(into: &block, count: blockSize)
            block.withUnsafeBufferPointer { buffer in
                pipeline.process(
                    buffer,
                    onPitch: { frame in
                        frames.append(frame)
                        scorer.add(frame, at: frame.time)
                    },
                    onColumn: { _ in }
                )
            }
            produced += blockSize
        }
        return (scorer.report(), frames, singer)
    }

    func testExactSingerScoresNearlyPerfect() {
        for voice in [VoiceRange.bass, .soprano] {
            let timeline = ExerciseTimeline(exercise: scale, tonicMidi: voice.tonicMidi)
            let report = perform(timeline: timeline, profile: .exact).report
            XCTAssertGreaterThan(report.score, 97, "\(voice)")
            XCTAssertLessThan(report.meanAbsoluteCents ?? 100, 3, "\(voice)")
        }
    }

    func testDemoSingerLandsInACredibleMiddle() {
        let timeline = ExerciseTimeline(exercise: scale, tonicMidi: VoiceRange.tenor.tonicMidi)
        let report = perform(timeline: timeline, profile: .demo).report
        XCTAssertGreaterThan(report.score, 60)
        XCTAssertLessThan(report.score, 99)
        XCTAssertLessThan(report.tendencyCents ?? 0, 0, "the demo profile is written to run flat")
    }

    func testAPlantedMistakeIsCaughtOnTheRightNote() {
        let timeline = ExerciseTimeline(exercise: scale, tonicMidi: VoiceRange.tenor.tonicMidi)
        let report = perform(timeline: timeline, profile: .exact, mistakes: [3: 45]).report
        for result in report.notes {
            if result.note.index == 3 {
                XCTAssertLessThan(result.score, 30)
                XCTAssertEqual(result.meanCents ?? 0, 45, accuracy: 5)
            } else {
                XCTAssertGreaterThan(result.score, 90, "note \(result.note.index)")
            }
        }
    }

    func testPipelineFollowsTheIntendedContour() throws {
        let held = Exercise(
            id: "held",
            numeral: "T",
            title: "Held notes",
            summary: "",
            tempo: 60,
            steps: [Exercise.Step(0, beats: 2), Exercise.Step(4, beats: 2)]
        )
        let timeline = ExerciseTimeline(exercise: held, tonicMidi: VoiceRange.alto.tonicMidi)
        let outcome = perform(timeline: timeline, profile: .demo)
        var errors: [Double] = []
        for frame in outcome.frames {
            guard let measured = frame.frequency,
                let intended = outcome.singer.score.frequency(at: frame.time),
                let note = timeline.note(at: frame.time),
                frame.time > note.start + 0.25,
                frame.time < note.end - 0.1
            else { continue }
            errors.append(abs(cents(measured, relativeTo: intended)))
        }
        XCTAssertGreaterThan(errors.count, 500)
        errors.sort()
        XCTAssertLessThan(errors[errors.count / 2], 3)
        XCTAssertLessThan(errors[errors.count * 95 / 100], 8)
    }

    func testRendersAreRepeatable() {
        let timeline = ExerciseTimeline(exercise: scale, tonicMidi: VoiceRange.mezzo.tonicMidi)
        let first = perform(timeline: timeline, profile: .demo).report
        let second = perform(timeline: timeline, profile: .demo).report
        XCTAssertEqual(first, second)
    }
}
