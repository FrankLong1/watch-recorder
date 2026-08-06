import XCTest

/// Drives the watch UI the way a person does.
///
/// Scope is deliberately "could a user tap through this?" — durable artifacts
/// (memo files, index ordering, capture cleanup) are `sim.sh`'s job. Keeping the
/// split makes a failure diagnosable: a red test here means the controls are
/// broken, not the storage layer.
///
/// Every transition uses `waitForExistence` rather than a hand-timed delay, so
/// simulator load slows the tests down instead of making them flaky.
final class RecordingFlowUITests: XCTestCase {

    private let timeout: TimeInterval = 20

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func launchApp(arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += arguments
        app.launch()
        return app
    }

    private func attachScreenshot(_ app: XCUIApplication, named name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Record → stop → saved → done, the whole happy path.
    func testRecordStopSaveFlow() {
        let app = launchApp()

        let record = app.buttons[AccessibilityID.recordButton]
        XCTAssertTrue(record.waitForExistence(timeout: timeout), "no Record button on Home")
        attachScreenshot(app, named: "1-home")
        record.tap()

        let status = app.staticTexts[AccessibilityID.recordingStatus]
        XCTAssertTrue(status.waitForExistence(timeout: timeout), "recording screen never appeared")
        attachScreenshot(app, named: "2-recording")

        // The timer must actually advance — a frozen 0:00.0 would mean the
        // ticker never started even though the screen switched.
        let timer = app.staticTexts[AccessibilityID.elapsedTimer]
        XCTAssertTrue(timer.waitForExistence(timeout: timeout))
        let first = timer.label
        let advanced = expectation(for: NSPredicate(format: "label != %@", first),
                                   evaluatedWith: timer)
        XCTAssertEqual(XCTWaiter.wait(for: [advanced], timeout: timeout), .completed,
                       "elapsed timer never advanced past \(first)")

        app.buttons[AccessibilityID.stopButton].tap()

        let saved = app.staticTexts[AccessibilityID.savedTitle]
        XCTAssertTrue(saved.waitForExistence(timeout: timeout), "Saved screen never appeared")
        attachScreenshot(app, named: "3-saved")

        app.buttons[AccessibilityID.doneButton].tap()

        XCTAssertTrue(record.waitForExistence(timeout: timeout), "did not return Home after Done")
        attachScreenshot(app, named: "4-home-with-memo")
    }

    /// Discarding must leave no trace on Home.
    func testDiscardReturnsHomeWithoutSaving() {
        let app = launchApp()

        let record = app.buttons[AccessibilityID.recordButton]
        XCTAssertTrue(record.waitForExistence(timeout: timeout))
        record.tap()

        XCTAssertTrue(app.staticTexts[AccessibilityID.recordingStatus].waitForExistence(timeout: timeout))
        app.buttons[AccessibilityID.discardButton].tap()

        XCTAssertTrue(record.waitForExistence(timeout: timeout), "discard did not return Home")
        // Straight back to Home — no Saved screen in between.
        XCTAssertFalse(app.staticTexts[AccessibilityID.savedTitle].exists,
                       "discard should never show the Saved screen")
        attachScreenshot(app, named: "discard-home")
    }

    /// Deleting from the Saved screen is the explicit undo described in
    /// ResultViews — it must not leave the memo behind.
    func testDeleteFromSavedScreenReturnsHome() {
        let app = launchApp()

        let record = app.buttons[AccessibilityID.recordButton]
        XCTAssertTrue(record.waitForExistence(timeout: timeout))
        record.tap()

        XCTAssertTrue(app.staticTexts[AccessibilityID.recordingStatus].waitForExistence(timeout: timeout))
        app.buttons[AccessibilityID.stopButton].tap()

        XCTAssertTrue(app.staticTexts[AccessibilityID.savedTitle].waitForExistence(timeout: timeout))
        app.buttons[AccessibilityID.deleteSavedButton].tap()

        XCTAssertTrue(record.waitForExistence(timeout: timeout), "delete did not return Home")
        attachScreenshot(app, named: "deleted-home")
    }

    /// The core promise in LATENCY.md: a launch triggered by the Action button
    /// draws the recording screen as its *first* frame, rather than showing Home
    /// and swapping. `-WristMemoAutoRecord` is the simulator stand-in for the
    /// same in-process request path.
    func testLaunchingWithAutoRecordOpensStraightIntoRecording() {
        let app = launchApp(arguments: ["-WristMemoAutoRecord", "YES"])

        let status = app.staticTexts[AccessibilityID.recordingStatus]
        XCTAssertTrue(status.waitForExistence(timeout: timeout),
                      "auto-record launch did not open on the recording screen")
        attachScreenshot(app, named: "autorecord-first-frame")

        // Home's Record button must never have been the landing screen.
        XCTAssertFalse(app.buttons[AccessibilityID.recordButton].exists,
                       "landed on Home instead of going straight into recording")

        app.buttons[AccessibilityID.stopButton].tap()
        XCTAssertTrue(app.staticTexts[AccessibilityID.savedTitle].waitForExistence(timeout: timeout))
    }
}
