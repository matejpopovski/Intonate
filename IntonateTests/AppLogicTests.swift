import IntonateDSP
import IntonateTraining
import XCTest

@testable import Intonate

final class WaterfallGeometryTests: XCTestCase {
    private let geometry = WaterfallGeometry(nowX: 0.75, pastSeconds: 3, lowMidi: 60, highMidi: 72)

    func testNowIsAtTheNowLine() {
        XCTAssertEqual(geometry.x(time: 10, now: 10), 0.75, accuracy: 1e-9)
    }

    func testPastEdgeAndFutureEdge() {
        XCTAssertEqual(geometry.x(time: 7, now: 10), 0, accuracy: 1e-9)
        XCTAssertEqual(geometry.futureSeconds, 1, accuracy: 1e-9)
        XCTAssertEqual(geometry.x(time: 11, now: 10), 1, accuracy: 1e-9)
    }

    func testPitchMapsLinearlyInSemitones() {
        XCTAssertEqual(geometry.y(midi: 60), 0)
        XCTAssertEqual(geometry.y(midi: 66), 0.5)
        XCTAssertEqual(geometry.y(midi: 72), 1)
    }

    func testRangeLeavesRoomAroundEveryExercise() throws {
        for exercise in Exercise.programme {
            for voice in VoiceRange.allCases {
                let timeline = ExerciseTimeline(exercise: exercise, tonicMidi: voice.tonicMidi)
                let range = WaterfallGeometry.range(for: timeline)
                let lowest = try XCTUnwrap(timeline.notes.map(\.midi).min())
                let highest = try XCTUnwrap(timeline.notes.map(\.midi).max())
                XCTAssertLessThanOrEqual(range.low, Double(lowest) - 3)
                XCTAssertGreaterThanOrEqual(range.high, Double(highest) + 3)
                XCTAssertGreaterThanOrEqual(range.high - range.low, 18)
            }
        }
    }

    func testFreeSingingCoversMostVoices() {
        let range = WaterfallGeometry.range(for: nil)
        XCTAssertLessThanOrEqual(range.low, 48)
        XCTAssertGreaterThanOrEqual(range.high, 79)
    }
}

final class LaunchOptionsTests: XCTestCase {
    func testDefaultsAreEmpty() {
        let options = LaunchOptions(arguments: ["Intonate"])
        XCTAssertNil(options.exerciseID)
        XCTAssertNil(options.voice)
        XCTAssertNil(options.measureSeconds)
        XCTAssertFalse(options.forceDemo)
    }

    func testParsesArguments() {
        let options = LaunchOptions(arguments: ["Intonate", "--demo", "--voice", "alto", "--exercise", "arpeggio"])
        XCTAssertEqual(options.exerciseID, "arpeggio")
        XCTAssertEqual(options.voice, .alto)
        XCTAssertTrue(options.forceDemo)
    }

    func testMeasuringImpliesFreeSingingInDemoMode() {
        let options = LaunchOptions(arguments: ["Intonate", "--measure", "20"])
        XCTAssertEqual(options.measureSeconds, 20)
        XCTAssertEqual(options.exerciseID, "free")
        XCTAssertTrue(options.forceDemo)
    }

    func testUnknownVoiceIsIgnored() {
        XCTAssertNil(LaunchOptions(arguments: ["Intonate", "--voice", "countertenor"]).voice)
    }
}

final class BestScoresTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite = ""

    override func setUp() {
        suite = "intonate.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testOnlyImprovementsAreKept() {
        let scores = BestScores(defaults: defaults)
        let exercise = Exercise.programme[0]
        XCTAssertNil(scores.best(for: exercise, voice: .tenor))
        XCTAssertTrue(scores.record(70, for: exercise, voice: .tenor))
        XCTAssertFalse(scores.record(60, for: exercise, voice: .tenor))
        XCTAssertTrue(scores.record(80, for: exercise, voice: .tenor))
        XCTAssertEqual(scores.best(for: exercise, voice: .tenor), 80)
    }

    func testVoicesAreKeptApart() {
        let scores = BestScores(defaults: defaults)
        let exercise = Exercise.programme[0]
        scores.record(90, for: exercise, voice: .soprano)
        XCTAssertNil(scores.best(for: exercise, voice: .bass))
    }
}

final class VerdictTests: XCTestCase {
    private let note = TimedNote(index: 2, midi: 64, start: 0, end: 1)

    private func report(tendency: Double?, noteCents: Double?) -> PerformanceReport {
        PerformanceReport(
            notes: [
                NoteResult(
                    note: note,
                    voicedFraction: 1,
                    meanCents: noteCents,
                    meanAbsoluteCents: noteCents.map(abs),
                    spreadCents: 0,
                    inTuneFraction: 1,
                    score: 80
                )
            ],
            score: 80,
            meanAbsoluteCents: noteCents.map(abs),
            tendencyCents: tendency,
            inTuneFraction: 1
        )
    }

    func testSilenceAsksAboutTheMicrophone() {
        XCTAssertTrue(ReviewView.verdict(report(tendency: nil, noteCents: nil)).contains("microphone"))
    }

    func testNamesTheHabitAndTheWorstNote() {
        let text = ReviewView.verdict(report(tendency: -12, noteCents: -20))
        XCTAssertTrue(text.contains("12 cents flat"))
        XCTAssertTrue(text.contains("E4"))
        XCTAssertTrue(text.contains("note 3"))
        XCTAssertTrue(text.contains("20 cents flat"))
    }

    func testASmallTendencyIsNotCalledAHabit() {
        XCTAssertTrue(ReviewView.verdict(report(tendency: 3, noteCents: 8)).hasPrefix("Centred"))
    }
}
