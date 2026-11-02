import XCTest

/// Walks the app as a person would, on the demo voice. Not part of CI: these wait on a real-time
/// exercise, which is fine on a developer's machine and needlessly slow on a shared runner.
final class StageFlowUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--voice", "tenor"] + arguments
        app.launch()
        return app
    }

    func testAnExerciseRunsFromTheProgrammeToTheNotices() {
        let app = launch()
        let row = app.buttons["exercise-octave-leaps"]
        for _ in 0..<4 where !row.isHittable {
            app.swipeUp()
        }
        row.tap()

        XCTAssertTrue(app.descendants(matching: .any)["demoBadge"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["sungNote"].waitForExistence(timeout: 20))

        let score = app.staticTexts["finalScore"]
        XCTAssertTrue(score.waitForExistence(timeout: 60))
        XCTAssertGreaterThan(Int(score.label) ?? -1, 0, "the demo singer must score something")

        app.buttons["backToProgrammeFromReview"].tap()
        XCTAssertTrue(app.staticTexts["Intonate"].waitForExistence(timeout: 10))
    }

    func testBackingOutOfAnExerciseReturnsToTheProgramme() {
        let app = launch(["--exercise", "long-tones"])
        XCTAssertTrue(app.buttons["backToProgramme"].waitForExistence(timeout: 20))
        app.buttons["backToProgramme"].tap()
        XCTAssertTrue(app.staticTexts["Intonate"].waitForExistence(timeout: 10))
    }

    func testVoiceChoiceChangesTheExercise() {
        let app = launch()
        app.buttons["voice-soprano"].tap()
        app.buttons["exercise-long-tones"].tap()
        XCTAssertTrue(app.staticTexts["Soprano voice"].waitForExistence(timeout: 10))
    }

    func testFreeStageShowsNoScoreLine() {
        let app = launch(["--exercise", "free"])
        XCTAssertTrue(app.staticTexts["Free stage: nothing is scored here."].waitForExistence(timeout: 20))
    }
}
