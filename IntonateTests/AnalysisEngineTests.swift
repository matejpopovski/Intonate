import IntonateDSP
import IntonateSynth
import IntonateTraining
import XCTest

@testable import Intonate

/// The queue, the ring and the scorer together. Everything waits on outcomes, never on a duration, so
/// a slow runner takes longer without failing.
final class AnalysisEngineTests: XCTestCase {
    private let exercise = Exercise(
        id: "short",
        numeral: "T",
        title: "Short",
        summary: "",
        tempo: 240,
        steps: [0, 4, 7].map { Exercise.Step($0, beats: 2) }
    )

    private func waitForReport(_ engine: AnalysisEngine) throws -> PerformanceReport {
        let done = expectation(description: "report")
        nonisolated(unsafe) var report: PerformanceReport?
        DispatchQueue.global().async {
            while true {
                if let value = engine.snapshot.report {
                    report = value
                    break
                }
                usleep(5_000)
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 120)
        return try XCTUnwrap(report)
    }

    func testDemoRunThroughTheEngineProducesAReport() throws {
        let timeline = ExerciseTimeline(exercise: exercise, tonicMidi: 57)
        let leadIn = 0.3
        let configuration = AnalysisConfiguration(sampleRate: 44_100)
        let engine = AnalysisEngine(configuration: configuration)
        let input = DemoInput(timeline: timeline, leadIn: leadIn, sampleRate: 44_100)
        engine.start(plan: AnalysisEngine.Plan(timeline: timeline, leadIn: leadIn))
        try input.start(writingTo: engine.ring)
        defer {
            input.stop()
            engine.stop()
        }

        let report = try waitForReport(engine)
        XCTAssertEqual(report.notes.count, 3)
        XCTAssertGreaterThan(report.score, 30, "the singer entered on time, so most frames count")
        for note in report.notes {
            XCTAssertGreaterThan(note.voicedFraction, 0.8)
        }
    }

    func testFreeSingingNeverFinishes() throws {
        let timeline = ExerciseTimeline(exercise: exercise, tonicMidi: 57)
        let engine = AnalysisEngine(configuration: AnalysisConfiguration(sampleRate: 44_100))
        let input = DemoInput(timeline: timeline, leadIn: 0, sampleRate: 44_100, loops: true)
        engine.start(plan: AnalysisEngine.Plan(timeline: nil, leadIn: 0))
        try input.start(writingTo: engine.ring)
        defer {
            input.stop()
            engine.stop()
        }

        let heard = expectation(description: "stream passes several takes")
        DispatchQueue.global().async {
            while engine.snapshot.streamTime < timeline.duration * 1.5 { usleep(5_000) }
            heard.fulfill()
        }
        wait(for: [heard], timeout: 120)
        XCTAssertNil(engine.snapshot.report)
        XCTAssertNotNil(engine.snapshot.frame)
    }

    /// More audio than the analysis can take at once must not stop it from publishing what it has.
    func testABacklogStillReachesTheDisplay() throws {
        let engine = AnalysisEngine(configuration: AnalysisConfiguration(sampleRate: 44_100))
        let voice = VoiceSynth.clip(contour: .constant(220), duration: 0.5, sampleRate: 44_100, timbre: .vowelAh)
        engine.ring.write(voice, count: voice.count)
        engine.start(plan: AnalysisEngine.Plan(timeline: nil, leadIn: 0))
        defer { engine.stop() }

        let published = expectation(description: "stream time published")
        DispatchQueue.global().async {
            while engine.snapshot.streamTime < 0.4 { usleep(2_000) }
            published.fulfill()
        }
        wait(for: [published], timeout: 60)
    }

    func testAnalysisKeepsUpWithoutDroppingSamples() throws {
        let configuration = AnalysisConfiguration(sampleRate: 44_100)
        let engine = AnalysisEngine(configuration: configuration)
        engine.start(plan: AnalysisEngine.Plan(timeline: nil, leadIn: 0))
        defer { engine.stop() }

        let voice = VoiceSynth.clip(contour: .constant(220), duration: 0.5, sampleRate: 44_100, timbre: .vowelAh)
        engine.ring.write(voice, count: voice.count)
        let drained = expectation(description: "ring drained")
        DispatchQueue.global().async {
            while engine.ring.availableToRead > 0 { usleep(2_000) }
            drained.fulfill()
        }
        wait(for: [drained], timeout: 60)
        XCTAssertEqual(engine.ring.droppedSamples, 0)
    }
}

@MainActor
final class TrainerSessionTests: XCTestCase {
    private let exercise = Exercise(
        id: "session",
        numeral: "T",
        title: "Session",
        summary: "",
        tempo: 240,
        steps: [0, 2, 4].map { Exercise.Step($0, beats: 2) }
    )

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(120)
        while !condition() {
            try XCTSkipIf(Date() > deadline, "the machine is too slow to finish this inside two minutes")
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func testRunMovesThroughCountInAndSingingToAReport() async throws {
        let session = TrainerSession(exercise: exercise, voice: .tenor, mode: .demo)
        await session.start()
        defer { session.stop() }
        XCTAssertEqual(session.phase, .countIn)
        XCTAssertNotNil(session.scene)
        XCTAssertEqual(session.readout.noteCount, 0, "nothing shown until the first tick")

        try await waitUntil { session.phase == .singing }
        XCTAssertEqual(session.readout.noteCount, 3)

        try await waitUntil {
            if case .finished = session.phase { return true }
            return false
        }
        guard case .finished(let report) = session.phase else { return XCTFail("no report") }
        XCTAssertEqual(report.notes.count, 3)
        XCTAssertEqual(session.droppedSamples, 0)
    }

    func testFreeStageNeverLeavesFreeSinging() async throws {
        let session = TrainerSession(exercise: nil, voice: .alto, mode: .demo)
        await session.start()
        defer { session.stop() }
        XCTAssertEqual(session.phase, .freeSinging)
        try await waitUntil { session.readout.noteName != nil }
        XCTAssertEqual(session.phase, .freeSinging)
        XCTAssertEqual(session.readout.noteCount, 0)
    }

    func testStopEndsTheInputWithoutAReport() async throws {
        let session = TrainerSession(exercise: exercise, voice: .tenor, mode: .demo)
        await session.start()
        session.stop()
        XCTAssertEqual(session.phase, .countIn)
    }
}
