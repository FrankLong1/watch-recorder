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

    @discardableResult
    private func waitFor(_ element: XCUIElement, _ what: String) -> XCUIElement {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "never saw \(what)")
        return element
    }

    /// Home → recording. Shared by every test that needs a recording underway.
    private func startRecording(_ app: XCUIApplication) {
        waitFor(app.buttons[AccessibilityID.recordButton], "the Record button").tap()
        waitFor(app.staticTexts[AccessibilityID.recordingStatus], "the recording screen")
    }

    /// Recording → saved.
    private func stopAndWaitForSaved(_ app: XCUIApplication) {
        app.buttons[AccessibilityID.stopButton].tap()
        waitFor(app.staticTexts[AccessibilityID.savedTitle], "the Saved screen")
    }

    /// Record → stop → saved → done, the whole happy path.
    func testRecordStopSaveFlow() {
        let app = launchApp()
        attachScreenshot(app, named: "1-home")
        startRecording(app)
        attachScreenshot(app, named: "2-recording")

        // The timer must actually advance — a frozen 0:00.0 would mean the
        // ticker never started even though the screen switched.
        let timer = waitFor(app.staticTexts[AccessibilityID.elapsedTimer], "the elapsed timer")
        let first = timer.label
        let advanced = expectation(for: NSPredicate(format: "label != %@", first),
                                   evaluatedWith: timer)
        XCTAssertEqual(XCTWaiter.wait(for: [advanced], timeout: timeout), .completed,
                       "elapsed timer never advanced past \(first)")

        stopAndWaitForSaved(app)
        attachScreenshot(app, named: "3-saved")

        app.buttons[AccessibilityID.doneButton].tap()
        waitFor(app.buttons[AccessibilityID.recordButton], "Home after Done")
        attachScreenshot(app, named: "4-home-with-memo")
    }

    /// Discarding must leave no trace on Home.
    func testDiscardReturnsHomeWithoutSaving() {
        let app = launchApp()
        startRecording(app)

        app.buttons[AccessibilityID.discardButton].tap()

        waitFor(app.buttons[AccessibilityID.recordButton], "Home after discard")
        // Straight back to Home — no Saved screen in between.
        XCTAssertFalse(app.staticTexts[AccessibilityID.savedTitle].exists,
                       "discard should never show the Saved screen")
        attachScreenshot(app, named: "discard-home")
    }

    /// Deleting from the Saved screen is the explicit undo described in
    /// ResultViews — it must not leave the memo behind.
    func testDeleteFromSavedScreenReturnsHome() {
        let app = launchApp()
        startRecording(app)
        stopAndWaitForSaved(app)

        app.buttons[AccessibilityID.deleteSavedButton].tap()

        waitFor(app.buttons[AccessibilityID.recordButton], "Home after delete")
        attachScreenshot(app, named: "deleted-home")
    }

    /// The core promise in LATENCY.md: a launch triggered by the Action button
    /// draws the recording screen as its *first* frame, rather than showing Home
    /// and swapping. `-WristMemoAutoRecord` is the simulator stand-in for the
    /// same in-process request path.
    func testLaunchingWithAutoRecordOpensStraightIntoRecording() {
        let app = launchApp(arguments: ["-WristMemoAutoRecord", "YES"])

        waitFor(app.staticTexts[AccessibilityID.recordingStatus], "the recording screen")
        attachScreenshot(app, named: "autorecord-first-frame")

        // Home's Record button must never have been the landing screen.
        XCTAssertFalse(app.buttons[AccessibilityID.recordButton].exists,
                       "landed on Home instead of going straight into recording")

        stopAndWaitForSaved(app)
    }
}
