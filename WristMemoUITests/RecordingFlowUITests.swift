import XCTest

/// Drives the watch UI the way a person does.
///
/// The interface is one full-screen button, so every assertion here is about
/// the same element: does tapping it toggle the word on it between READY and
/// RECORDING. That word is the button's accessibility *value* rather than a
/// separate label — SwiftUI folds a button's contents into one accessibility
/// node, so there is nothing else to query, and asserting on a `staticText`
/// inside the button would pass or fail on an implementation detail.
///
/// Scope is deliberately "could a user tap through this?" — durable artifacts
/// (memo files, index ordering, capture cleanup) are `sim.sh`'s job. Keeping the
/// split makes a failure diagnosable: a red test here means the control is
/// broken, not the storage layer.
///
/// Every transition uses a predicate wait rather than a hand-timed delay, so
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

    private func button(_ app: XCUIApplication) -> XCUIElement {
        app.buttons[AccessibilityID.recordButton]
    }

    /// Waits for the one control to be showing a given word.
    ///
    /// `value`, not `label`: the label is the fixed name of the control
    /// ("Record"), and the state is the value, exactly as VoiceOver reads it.
    @discardableResult
    private func waitForStatus(_ app: XCUIApplication, _ expected: String) -> XCUIElement {
        let control = button(app)
        let matched = expectation(
            for: NSPredicate(format: "value == %@", expected),
            evaluatedWith: control
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [matched], timeout: timeout), .completed,
            "never saw \(expected); the control read \(String(describing: control.value))"
        )
        return control
    }

    /// Tap to start, tap to stop, and the app is ready again with nothing else
    /// tapped. The whole interface, in one test.
    func testTappingTheScreenTogglesRecording() {
        let app = launchApp()
        waitForStatus(app, AccessibilityID.StatusText.ready)
        attachScreenshot(app, named: "1-ready")

        button(app).tap()
        waitForStatus(app, AccessibilityID.StatusText.recording)
        attachScreenshot(app, named: "2-recording")

        button(app).tap()
        // Straight back to READY — the memo compresses and syncs behind this,
        // and the point of the change is that the user never waits for it.
        waitForStatus(app, AccessibilityID.StatusText.ready)
        attachScreenshot(app, named: "3-ready-again")
    }

    /// The second thought arrives while the first is still encoding. Starting
    /// again immediately must work, because nothing blocks after a stop.
    func testCanStartAgainImmediatelyAfterStopping() {
        let app = launchApp()
        waitForStatus(app, AccessibilityID.StatusText.ready)

        button(app).tap()
        waitForStatus(app, AccessibilityID.StatusText.recording)
        button(app).tap()
        waitForStatus(app, AccessibilityID.StatusText.ready)

        button(app).tap()
        waitForStatus(app, AccessibilityID.StatusText.recording)
        button(app).tap()
        waitForStatus(app, AccessibilityID.StatusText.ready)
    }

    /// The core promise in LATENCY.md: a launch triggered by the Action button
    /// is already recording, rather than showing a ready screen and swapping.
    /// `-WristMemoAutoRecord` is the simulator stand-in for the same in-process
    /// request path.
    func testLaunchingWithAutoRecordOpensStraightIntoRecording() {
        let app = launchApp(arguments: ["-WristMemoAutoRecord", "YES"])

        waitForStatus(app, AccessibilityID.StatusText.recording)
        attachScreenshot(app, named: "autorecord-first-frame")

        button(app).tap()
        waitForStatus(app, AccessibilityID.StatusText.ready)
    }
}
