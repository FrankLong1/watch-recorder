import XCTest

/// Drives the watch UI the way a person does.
///
/// The interface is one full-screen button, so every assertion here is about
/// the same element: OFF ignores taps and RECORDING stops. That state is the
/// button's accessibility *value* rather than a
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
    /// ("WristMemo"), and the state is the value, exactly as VoiceOver reads it.
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

    private func assertStatusRemains(_ app: XCUIApplication, _ expected: String) {
        let control = button(app)
        let changed = expectation(
            for: NSPredicate(format: "value != %@", expected),
            evaluatedWith: control
        )
        changed.isInverted = true
        XCTAssertEqual(
            XCTWaiter.wait(for: [changed], timeout: 1.5), .completed,
            "status changed after an inert tap; the control read \(String(describing: control.value))"
        )
    }

    /// Starting belongs exclusively to the Action Button. The idle screen is
    /// instruction, not a hidden second Record button.
    func testOffTapDoesNotStart() {
        let app = launchApp()
        waitForStatus(app, AccessibilityID.StatusText.idle)
        attachScreenshot(app, named: "1-off")

        button(app).tap()
        assertStatusRemains(app, AccessibilityID.StatusText.idle)
    }

    /// The core promise in LATENCY.md: a launch triggered by the Action button
    /// is already recording, rather than showing a ready screen and swapping.
    /// `-WristMemoAutoRecord` is the simulator stand-in for the same in-process
    /// request path.
    func testLaunchingWithAutoRecordOpensStraightIntoRecording() {
        let app = launchApp(arguments: ["-WristMemoAutoRecord", "YES"])

        waitForStatus(app, AccessibilityID.StatusText.recordingControl)
        attachScreenshot(app, named: "autorecord-first-frame")

        button(app).tap()
        waitForStatus(app, AccessibilityID.StatusText.completionReceipt)
    }

    /// Leaving WristMemo is an intentional stop. Relaunching without a new
    /// Action Button request must return idle rather than resume the old memo.
    func testExitingStopsRecording() {
        let app = launchApp(arguments: ["-WristMemoAutoRecord", "YES"])
        waitForStatus(app, AccessibilityID.StatusText.recordingControl)

        XCUIDevice.shared.press(.home)
        app.launchArguments = []
        app.launch()

        waitForStatus(app, AccessibilityID.StatusText.idle)
    }
}
